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

type statement = {
	lazy_inst : statement_instance Lazy.t;
	mutable forced : bool;
	mutable finalized : bool;
}

let instance st =
	if st.finalized then failwith "Sqlite3EZ: attempt to use finalized statement"
	st.forced <- true
	Lazy.force st.lazy_inst

let make_statement' db sql =
	let inst =
		lazy
			let stmt = prepare db sql
			{stmt = stmt; parameter_count = bind_parameter_count stmt; in_progress = false}
	let x = { lazy_inst = inst; forced = false; finalized = false }
	Gc.finalise (function { forced = true; finalized = false; lazy_inst } -> ignore (finalize (Lazy.force lazy_inst).stmt) | _ -> ()) x
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
		y
	with
		| exn ->
			instance.in_progress <- false
			try check_rc (reset instance.stmt) with exn2 -> raise (Finally (exn,exn2))
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
	if x.forced && not x.finalized then
		let inst = instance x
		if inst.in_progress then failwith "Sqlite3EZ: attempt to finalize in-progress statement"
		x.finalized <- true
		ignore (finalize inst.stmt)
	else
		x.finalized <- true

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

let db_open fn = 
	let h = db_open fn
	let x =
		{ h = h;
			still_open = true;
			statement_begin = make_statement' h "BEGIN";
			statement_commit = make_statement' h "COMMIT";
			statement_rollback = make_statement' h "ROLLBACK";
			statement_savepoint = make_statement' h "SAVEPOINT ?";
			statement_release = make_statement' h "RELEASE ?";
			statement_rollback_to = make_statement' h "ROLLBACK TO ?";
			 } 
	Gc.finalise (function { still_open = true; h } -> ignore (db_close h) | _ -> ()) x
	x

let db_close = function
	| x when x.still_open = true -> 
		x.still_open <- false
		ignore (db_close x.h)
	| _ -> ()

let db_handle { h } = h

let exec { h } sql = check_rc (exec h sql)

let empty = [||]
let transact db f x =
	statement_exec db.statement_begin empty
	try
		let y = f db x
		statement_exec db.statement_commit empty
		y
	with
		| exn ->
			try statement_exec db.statement_rollback empty with exn' -> raise (Finally (exn,exn'))
			raise exn

let p = [| Data.TEXT "A" |]
let atomically db f x =
	statement_exec db.statement_savepoint p
	try
		let y = f db x
		statement_exec db.statement_release p
		y
	with
		| exn ->
			try
				statement_exec db.statement_rollback_to p
				statement_exec db.statement_release p
			with exn' -> raise (Finally (exn,exn'))
			raise exn

let last_insert_rowid db = last_insert_rowid db.h

let make_statement { h } sql = make_statement' h sql
