open List
open Sqlite3

module Rc = Sqlite3.Rc
module Data = Sqlite3.Data

exception Rc of Rc.t
exception Finally of exn*exn

let check_rc = function
	| Rc.OK | Rc.DONE -> ()
	| rc -> raise (Rc rc)
let bindall stmt a = Array.iteri (fun i x -> check_rc (bind stmt (i+1) x)) a

type statement_instance = {
	stmt : stmt;
	parameter_count : int;
	mutable in_progress : bool;
}

type statement_status = New | Instantiated | Finalized
type statement = {
	lazy_inst : statement_instance Lazy.t;
	mutable status : statement_status;
}

let instance st =
	if st.status = Finalized then failwith "Sqlite3EZ: attempt to use finalized statement"
	st.status <- Instantiated
	Lazy.force st.lazy_inst

let statement_finaliser = function
	| { status = Instantiated; lazy_inst } as st ->
		ignore (finalize (Lazy.force lazy_inst).stmt)
		st.status <- Finalized
	| _ -> ()

let make_statement' db sql =
	let inst =
		lazy
			let stmt = prepare db sql
			{stmt = stmt; parameter_count = bind_parameter_count stmt; in_progress = false }
	let x = { lazy_inst = inst; status = New }
	Gc.finalise statement_finaliser x
	x

let finally_reset statement f =
	(* TODO handle expired/recompile *)
	let instance = instance statement
	if instance.in_progress then failwith "Sqlite3EZ: attempt to execute statement already in progress"
	instance.in_progress <- true
	try
		let y = f instance
		instance.in_progress <- false
		check_rc (reset instance.stmt)
		statement.status <- statement.status (* trick GC into keeping statement until now *)
		y
	with
		| exn ->
			instance.in_progress <- false
			try check_rc (reset instance.stmt) with exn2 -> raise (Finally (exn,exn2))
			statement.status <- statement.status (* trick GC into keeping statement until now *)
			raise exn
			

let statement_exec statement parameters =
	finally_reset statement
		fun instance ->
			if Array.length parameters <> instance.parameter_count then
				invalid_arg "Sqlite3EZ.statement_exec: wrong number of parameters"
			bindall instance.stmt parameters
			let rc = ref Rc.OK
			while !rc <> Rc.DONE do
				rc := step instance.stmt
				if !rc = Rc.ROW then failwith "Sqlite3EZ.statement_exec: not a (_ -> unit) statement"
				check_rc !rc

let statement_query statement parameters cons fold init =
	finally_reset statement
		fun instance ->
			if Array.length parameters <> instance.parameter_count then
				invalid_arg "Sqlite3EZ.statement_query : wrong number of parameters"
			bindall instance.stmt parameters

			let arbox = ref None
			let x = ref init
			let rc = ref (step instance.stmt)
			while !rc = Rc.ROW do
				let k = data_count instance.stmt
				let ar = match !arbox with
					| Some ar when Array.length ar = k -> ar
					| Some _ -> failwith "Sqlite3EZ.statement_query: varying number of result columns"
					| None ->
						let ar = Array.make k Data.NULL
						arbox := Some ar
						ar
				for i = 0 to k - 1 do
					ar.(i) <- column instance.stmt i
				x := fold (cons ar) !x
				rc := step instance.stmt
			check_rc !rc
			!x
			
let statement_finalize x =
	if x.status = Instantiated then
		let inst = instance x
		check_rc (finalize inst.stmt)
	x.status <- Finalized

type db = {
	h : Sqlite3.db;
	mutable still_open : bool;
	
	statement_begin : statement;
	statement_commit : statement;
	statement_rollback : statement;

	statement_savepoint : statement;
	statement_release : statement;
	statement_rollback_to : statement;
}

let db_finaliser = function
	| { still_open = true; h} -> ignore (db_close h)
	| _ -> ()

let wrap_db h = { h = h;
			still_open = true;
			statement_begin = make_statement' h "BEGIN";
			statement_commit = make_statement' h "COMMIT";
			statement_rollback = make_statement' h "ROLLBACK";
			statement_savepoint = make_statement' h "SAVEPOINT a";
			statement_release = make_statement' h "RELEASE a";
			statement_rollback_to = make_statement' h "ROLLBACK TO a";
			 } 
	
let db_open ?mode ?mutex ?cache ?vfs fn =
	let h = db_open ?mode ?mutex ?cache ?vfs fn
	let x = wrap_db h
	Gc.finalise db_finaliser x
	x

let db_close = function
	| x when x.still_open = true -> 
		x.still_open <- false
		ignore (db_close x.h)
	| _ -> ()

let with_db ?mode ?mutex ?cache ?vfs fn f =
	let db = db_open ?mode ?mutex ?cache ?vfs fn
	try
		let y = f db
		db_close db
		y
	with
		| exn ->
			try db_close db with exn' -> raise (Finally (exn,exn'))
			raise exn

let db_handle { h } = h

let exec { h } sql = check_rc (exec h sql)

let empty = [||]
let transact db f =
	statement_exec db.statement_begin empty
	try
		let y = f db
		statement_exec db.statement_commit empty
		y
	with
		| exn ->
			try statement_exec db.statement_rollback empty with exn' -> raise (Finally (exn,exn'))
			raise exn

let atomically db f =
	statement_exec db.statement_savepoint [||]
	try
		let y = f db
		statement_exec db.statement_release [||]
		y
	with
		| exn ->
			try
				statement_exec db.statement_rollback_to [||]
				statement_exec db.statement_release [||]
			with exn' -> raise (Finally (exn,exn'))
			raise exn

let last_insert_rowid db = last_insert_rowid db.h

let changes db = changes db.h

let make_statement { h } sql = make_statement' h sql

let named_parameters stmt alist =
  let instance = instance stmt
  let arr = Array.init instance.parameter_count (fun _ -> None)
  List.iter
    fun (name, data) ->
      let idx = bind_parameter_index instance.stmt name
      if arr.(idx) = None then
        arr.(idx) <- Some data
      else
        failwith ("Duplicate bind parameter: " ^ name)
    alist
  Array.mapi
    fun i -> function
      | Some v -> v
      | None ->
        let name = match bind_parameter_name instance.stmt i with
          | Some v -> v
          | None -> string_of_int i
        failwith ("Parameter not bound: " ^ name)
    arr

let column_names stmt =
  let instance = instance stmt
  Array.init
      column_count instance.stmt
      column_name instance.stmt

let with_statement db ~sql f =
  let stmt = make_statement db sql
  let r =
    try ignore (instance stmt); f stmt
    with e -> statement_finalize stmt; raise e
  statement_finalize stmt
  r
