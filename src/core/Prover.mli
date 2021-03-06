(* This file is free software. See file "license" for more details. *)

(** {1 Run Prover}

    Utils to run a theorem prover (or a similar tool) and extract its result
*)

module Fmt = CCFormat
module E = CCResult
module Db = Sqlite3_utils
type 'a or_error = ('a, string) E.t

(** {2 Prover configurations} *)

type version =
  | Tag of string
  | Git of {
      branch: string;
      commit: string;  (* branch & commit hash *)
    }

type name = string

type t = {
  (* Prover identification *)
  name : name;
  version : version;

  (* Pover execution *)
  binary: string;       (* name of the program itself *)
  binary_deps: string list; (* list of binaries this depends on *)
  cmd: string;          (* the command line to run.
                           possibly contains $binary, $file, $memory and $timeout *)

  (* Result analysis *)
  unsat   : string option;  (* regex for "unsat" *)
  sat     : string option;  (* regex for "sat" *)
  unknown : string option;  (* regex for "unknown" *)
  timeout : string option;  (* regex for "timeout" *)
  memory  : string option;  (* regex for "out of memory" *)
  custom  : (string * string) list; (* custom tags *)
  defined_in: string option;
}
(** The type of provers configurations *)

val name : t -> name
(** Prover name *)

val compare_name : name -> name -> int
val compare_by_name : t -> t -> int
val pp_name : t Fmt.printer
val pp : t Fmt.printer

(** Version *)
module Version : sig
  type t = version
  val pp : t Fmt.printer

  val to_string_short : t -> string

  val to_sexp : t -> Sexp_loc.t
  val sexp_decode : t Sexp_loc.D.decoder
  val ser_sexp : t -> string
  val deser_sexp : string -> t or_error
end

val equal : t -> t -> bool
(** Equality (by name) *)

exception Subst_not_found of string

val interpolate_cmd :
  ?env:(string * string) array ->
  ?binary:string ->
  ?timeout:int -> ?memory:int -> ?file:string ->
  ?f:(string -> string option) ->
  string -> string
(** Interpolate the given parameters (env, timeout, memory, etc.)
    in the given string.
    @param f called for other interpolations
    @raise Subst_not_found if a variable is found, that is not substituted
    into any of the parameters nor by [f] *)

val make_command :
  ?env:(string * string) array ->
  t ->
  timeout:int ->
  memory:int ->
  file:string ->
  string

val run :
  ?env:(string * string) array ->
  timeout:int ->
  memory:int ->
  file:string ->
  t ->
  Proc_run_result.t

val analyze_p_opt : t -> Proc_run_result.t -> Res.t option
(** Analyze raw result to look for the result *)

(** Map by name *)
module Map_name : CCMap.S with type key = t

(** Map with full compare *)
module Map : CCMap.S with type key = t
module Set : CCSet.S with type elt = t

val db_prepare : Db.t -> unit or_error

val to_db : Db.t -> t -> unit or_error

val of_db : Db.t -> name -> t or_error
val tags_of_db : Db.t -> string list

val db_names : Db.t -> name list or_error
(** Names of provers in this DB *)
