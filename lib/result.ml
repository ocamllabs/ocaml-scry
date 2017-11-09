(*
 * Copyright (c) 2013 David Sheets <sheets@alum.mit.edu>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Sexplib.Std

module Uri = struct
  include Uri
  let t_of_sexp sexp =
    of_string (Sexplib.Std.string_of_sexp sexp)
  let sexp_of_t uri = Sexplib.Std.sexp_of_string (to_string uri)
end

(* ordered minor to severe *)
type solver_error =
  | Incompatible
  | Unsatisfied_dep of string (* TODO: this is pkg + constraint right now *)
[@@deriving sexp]

(* ordered minor to severe *)
type system_error =
  | No_space
  | Worker_is_root
[@@deriving sexp]

(* ordered minor to severe *)
type meta_error =
  | Checksum of Uri.t * string * string
  | Ocamlfind_dep of string
  | Findlib_constraint of string * string
[@@deriving sexp]

(* ordered minor to severe *)
type ext_dep_error =
  | Opam_depext of string
  | Wrong_depext of string * string
  | Pkg_config_constraint of string * string
  | Pkg_config of string
  | Command of string
  | Header of string
  | C_libs of string list
[@@deriving sexp]

(* ordered minor to severe *)
type transient_error =
  | Broken_link of Uri.t
  | Opam_metadata of Uri.t
[@@deriving sexp]

(* ordered minor to severe *)
type build_error =
  | Error_for_warn
  | Compilation of string * string * string
[@@deriving sexp]

(* ordered minor to severe *)
type analysis =
  | Solver of solver_error option
  | Dep of string * analysis
  | Transient of transient_error
  | System of system_error
  | Meta of meta_error
  | Ext_dep of ext_dep_error
  | Build of build_error
  | Multiple of analysis list
[@@deriving sexp]

type error =
  | Process of Repo.proc_status * Repo.r
  | Other of string * string
[@@deriving sexp]

type status =
  | Passed of Repo.r
  | Failed of analysis * error
[@@deriving sexp]

type t = {
  status : status;
  duration : Time.duration;
  info : string;
} [@@deriving sexp]

let is_failure = function Passed _ -> false | Failed (_,_) -> true

let get_status {status} = status

let rec worst_of_analysis a = match a with
  | Solver _ | Dep (_,_) | Transient _ | System _
  | Meta _   | Ext_dep _ | Build _     | Multiple [] -> a
  | Multiple analyses ->
      List.fold_left (fun w n -> max w (worst_of_analysis n))
        (Solver (Some Incompatible)) analyses

let rec class_string_of_analysis = function
  | Multiple [] -> "error"
  | Multiple xs -> class_string_of_analysis (worst_of_analysis (Multiple xs))
  | Build Error_for_warn -> "errwarn"
  | Build (Compilation _) -> "compile"
  | Solver None
  | Solver (Some Incompatible) -> "incompat"
  | Solver (Some (Unsatisfied_dep _))
  | Dep (_,_) -> "dep"
  | Meta _ -> "meta"
  | System _ -> "system"
  | Transient _ -> "trans"
  | Ext_dep _ -> "extdep"

let rec match_global ?(pos=0) ?(lst=[]) re s =
  let ofs = try Re.(get_all_ofs (exec ~pos re s))
    with Not_found -> [|-1,-1|] in
  if ofs.(0) = (-1,-1) then lst
  else
    let matches =
      ofs.(0), Array.map
        (fun (a,z) -> if a = (-1) || z = (-1) then "" else String.sub s a (z-a))
        ofs in
    match_global ~pos:(snd ofs.(0)) ~lst:(matches::lst) re s

let unsat_dep_re = Re.(compile (
  (* seq [
  (* tested 2013/6/21 *)
    str "The dependency ";
    group (rep1 (compl [space]));
    str " of package ";
    group (rep1 (compl [space]));
    str " is not available";]; *)
  seq [
    str "The following dependencies couldn't be met:";
    rep1 (compl [set "-"]);
    str "- ";
    group (rep1 (compl [space]));
    str " -> ";
    shortest (group (rep1 any));
    eol;
]))
let no_solution_re = Re.(compile (seq [
  str "No package matches ";
  rep1 (compl [set "."]);
  rep1 any;
  (* rep (alt [str "."; space; eol]); *)
  str "No solution found, exiting";
  opt (seq [
    rep1 (compl [set "\'"]);
    str "\'opam install ";
    rep1 (compl [set "\'"]);
    str "\' failed.";]);
]))
let solver_errors_of_r { Repo.r_args; r_stdout } =
  let matches_unsat = match_global unsat_dep_re r_stdout in
  let matches_nosol = match_global no_solution_re r_stdout in
  if not (0 = List.length matches_unsat) then
    Multiple (List.fold_left (fun lst (_,m) ->
      let err = Solver (Some (Unsatisfied_dep m.(2))) in
      let pkg = try m.(1) with _ -> "" in
      if List.mem pkg r_args then err::lst
      else (Dep (pkg, err))::lst) [] matches_unsat)
  else if not (0 = List.length matches_nosol) then Solver None
  else Multiple []

let pkg_build_error_re = Re.(compile (seq [
  (* tested 2013/6/21 *)
  rep1 (set "=");
  alt [space; rep1 (compl [upper])];
  str "ERROR";
  alt [space; rep1 (compl [set "w"])];
  str "while installing ";
  group (rep1 (compl [space]));
]))

let no_space_recognizer = Re.((* tested 2013/6/26 *)
  str "No space left on device", (fun _ -> System No_space)
)

let configure_must_not_run_as_root = Re.(
  str "configure script must not be run with root user",
  (fun _ -> System Worker_is_root)
)

let compile_pair (re,cons) = (Re.compile re,cons)
let build_error_stderr_re = Re.(List.map compile_pair [
  seq [ (* tested 2013/6/21 *)
    str "Wrong checksum for ";
    group (rep1 notnl);
    str "\n  - ";
    group (rep1 (compl [space]));
    str " [expected result]\n  - ";
    group (rep1 (compl [space]));
    str " [actual result]";
  ], (fun m -> Meta
    (Checksum (Uri.of_string (String.sub m.(1) 0 ((String.length m.(1)) - 1)),
               m.(2), m.(3))));
  seq [ (* tested 2013/6/21 *)
    str "configure: error: ";
    group (rep1 (compl [space]));
    alt [str " not found"; str " is required"];
  ], (fun m -> Ext_dep (Pkg_config m.(1)));
  seq [ (* tested 2013/6/26 *)
    str "configure: error: Cannot find ";
    group (rep1 (compl [set "."]));
    str ".";
  ], (fun m -> Ext_dep (C_libs [m.(1)]));
  seq [ (* tested 2013/6/21 *)
    str "Cannot get ";
    group (rep1 notnl);
  ], (fun m -> Transient (Broken_link (Uri.of_string m.(1))));
  seq [
    str "[ERROR] curl: code ";
    rep1 (compl [space]);
    str " while downloading";
    rep1 (alt [eol; space]);
    group (rep1 notnl);
  ], (fun m -> Transient (Broken_link (Uri.of_string m.(1))));
  seq [ (* *)
    str "Internal error:\n";
    rep space;
    group (rep1 (compl [space]));
    str " is not available.";
  ], (fun m -> Transient (Broken_link (Uri.of_string m.(1))));
  seq [ (* tested 2013/6/26 *)
    str "Internal error:";
    rep (alt [eol; space]);
    str "\"";
    group (rep1 (compl [set "\""]));
    str "\": command not found.";
  ], (fun m -> Ext_dep (Command m.(1)));
  no_space_recognizer;
  configure_must_not_run_as_root;
])

let build_error_stdout_re = Re.(List.map compile_pair [
  str "Error: Error-enabled warnings", (* tested 2013/6/21 *)
  (fun _ -> Build Error_for_warn);
  seq [ (* tested 2013/6/21 *)
    str "Package ";
    group (rep1 (compl [space]));
    str " was not found in the pkg-config search path";
  ], (fun m -> Ext_dep (Pkg_config m.(1))); (*
  seq [ (* tested 2013/6/21 *)
    str "checking whether pkg-config knows about ";
    group (rep1 (compl [space]));
    str " ";
    group (seq [compl [set "o"]; shortest (rep1 any)]);
    str "... "; compl [set "o"];
  ], (fun m -> Ext_dep (Pkg_config_constraint (m.(1),m.(2)))); *)
  seq [ (* tested 2013/6/21 *)
    str ": ";
    opt (str "fatal ");
    str "error: ";
    group (shortest (rep1 any) (*(compl [set "."])*));
    str ".h: No such file or directory";
  ], (fun m -> Ext_dep (Header m.(1)));
  seq [ (* tested 2013/6/26 *)
    str ": fatal error: '";
    group (non_greedy (rep1 any));
    str ".h' file not found";
  ], (fun m -> Ext_dep (Header m.(1)));
  seq [
    str "configure: error: ";
    group (rep1 (compl [space]));
    str " headers not found.";
    ], (fun m -> Ext_dep (Header m.(1)));
  seq [ (* tested 2013/6/26 *)
    str "make: ";
    group (rep1 (compl [set ":"]));
    str ": ";
    alt [str "C"; str "c"];
    str "ommand not found";
  ], (fun m -> Ext_dep (Command m.(1)));
  seq [ (* tested 2013/6/28 *)
    str "configure: error: '";
    group (rep1 (compl [set "'"]));
    str "' command not found";
  ], (fun m -> Ext_dep (Command m.(1)));
  seq [ (* tested 2013/7/3 *)
    opt (str "/bin/");
    alt [str "sh: "; str "env: "; str "make: "];
    opt (seq [rep1 digit; str ": "]);
    group (rep1 (compl [set ":"]));
    str ": ";
    alt [
      seq [
        opt (str "command ");
        str "not found";
      ];
      str "No such file or directory";
    ];
  ], (fun m -> Ext_dep (Command m.(1)));
  seq [ (* tested 2013/6/21 *)
    str "ocamlfind: Package `";
    group (rep1 (compl [set "'"]));
    str "' not found";
  ], (fun m -> Meta (Ocamlfind_dep m.(1)));
  seq [ (* tested 2013/6/21 *)
    str "E: Cannot find findlib package ";
    group (rep1 (compl [space]));
    opt (seq [str " ("; group (rep1 (compl [set ")"]))]);
  ], (fun m -> Meta (Findlib_constraint (m.(1),try m.(2) with _ -> "")));
  seq [ (* tested 2013/6/21 *)
    str "The following re";
    opt (char 'c');
    str "quired C libraries are missing:";
    group (rep1 (seq [char ' '; rep1 (compl [space])]));
    str ".";
  ], (fun m -> Ext_dep (C_libs Re_str.(split (regexp_string " ") m.(1))));
  seq [ (* tested 2013/6/26 *)
    str "ld: library not found for -l";
    group (rep1 notnl);
  ], (fun m -> Ext_dep (C_libs [m.(1)]));
  seq [ (* tested 2013/6/28 *)
    str "ld: cannot find -l";
    group (rep1 notnl);
  ], (fun m -> Ext_dep (C_libs [m.(1)]));
  seq [
    str "--external=source,";
    group (rep1 (compl [space]));
    rep1 any;
    str "E: Unable to locate package ";
    group (rep1 (compl [space]))
  ], (fun m -> Ext_dep (Wrong_depext (m.(2), m.(1))));
  seq [
    str "--external=source,";
    group (rep1 (compl [space]));
    rep1 any;
    str "No package ";
    group (rep1 (compl [space]));
    str " available."
    ], (fun m -> Ext_dep (Wrong_depext (m.(2), m.(1))));
  seq [
    str "[ERROR] The compilation of ";
    group (rep1 (compl [space]));
    str " failed at \"pkg-config";
    rep1 (alt [space; eol]);
    group (rep1 (compl [set "\""]));
    str "\".";
  ], (fun m -> Ext_dep (Pkg_config m.(2)));
  seq [
    str "configure: error: ";
    group (rep1 (compl [set "."]));
    str ".pc not found.. Do you need to set PKG_CONFIG_PATH?"
  ], (fun m -> Ext_dep (Pkg_config m.(1)));
  seq [
    str "configure: error: Package requirements (";
    group (rep1 (compl [space]));
    str " ";
    group (rep1 (compl [set ")"]));
    str ") were not met"
  ], (fun m -> Ext_dep (Pkg_config_constraint (m.(1), m.(2))));
  seq [
    str "opam-depext: internal error, uncaught exception:";
    rep1 (alt [eol; space]);
    str "Failure(";
    group (rep1 (compl [set ")"]));
    str ")";
  ], (fun m -> Ext_dep (Opam_depext m.(1)));
  seq [
    str "File \"";
    group (rep1 (compl [set "\""]));
    str "\", line ";
    group (rep1 digit);
    alt [
      str ":";
      seq [
        str ", characters ";
        group (rep1 (compl [set ":"]));
        str ":";]];
    rep1 (compl [upper]);
    (* rep1 (alt [set "#-"; space; eol]); *)
    str "Error: ";
    ], (fun m -> Build (Compilation (m.(1), m.(2), m.(3))));
  no_space_recognizer;
  configure_must_not_run_as_root;
])

let rec search k str = function
  | [] -> k ()
  | (patt,cons)::r ->
      (try cons (Re.get_all (Re.exec patt str))
       with Not_found -> search k str r)

(* given a string `str' and a list of constructors on regex patterns,
   find the last match in `str' for all patterns *)
let rec last_match ?x str = function
  | [] -> begin match x with Some (c,_) -> Some c | None -> None end
  | (patt,cons)::r -> begin match match_global patt str with
      | [] -> last_match ?x str r
      | ms ->
          let maxm = List.fold_left
            (fun (c,z) ((_,z'),m) -> if z > z' then (c,z) else (m,z'))
            ([||],-1) ms
          in begin match x with
            | Some (_,lmofs) when lmofs > snd maxm -> last_match ?x str r
            | _ -> last_match ~x:(cons (fst maxm), snd maxm) str r
          end
  end

(* TODO: catch multiple package failures and ensure they match their errors *)
let build_errors_of_r { Repo.r_args; r_stderr; r_stdout } =
  let pkg = try Re.(get (exec pkg_build_error_re r_stderr) 1) with _ -> "" in
  let err = match last_match r_stdout build_error_stdout_re with
    | Some c -> c
    | None -> search (fun () -> Multiple []) r_stderr build_error_stderr_re
  in
  if List.mem pkg r_args then err
  else if not (pkg = "" && err = Multiple []) then Dep (pkg, err)
  else Multiple []

let incompatible_error_re = Re.(compile (seq [
  (* tested 2013/6/21 *)
  bol; str "Version "; rep1 (compl [space]);
  str " of \""; rep1 (compl [set "\""]);
  str "\" is not available for your compiler or your OS";
]))
let other_errors_of_r { Repo.r_stderr } =
  try
    if Re.execp incompatible_error_re r_stderr
    then Solver (Some Incompatible)
    else Multiple []
  with _ -> Multiple []

let system_error_stderr_re = Re.(List.map compile_pair [
  seq [ (* tested 2013/6/29 *)
    str "Cannot download ";
    group (non_greedy (rep1 any));
    str ", please check your connection settings.";
  ], (fun m -> Transient (Opam_metadata (Uri.of_string m.(1))));
  no_space_recognizer;
  configure_must_not_run_as_root;
])
let system_errors_of_r { Repo.r_stderr } =
  try begin match last_match r_stderr system_error_stderr_re with
    | Some c -> c
    | None -> Multiple []
  end with _ -> Multiple []

let analyze_all = Repo.(function
  | Process (_, r) -> begin
      (* let analyzers = [build_errors_of_r] in *)
      let analyzers = [ system_errors_of_r; solver_errors_of_r; build_errors_of_r;
                        other_errors_of_r ] in
      let results = List.filter (fun err -> not (err = Multiple []))
                                (List.map (fun a -> a r) analyzers) in
      Multiple results end
  | _ -> Multiple []
)

let analyze = Repo.(function
  | Process (Exited 1,
             ({ r_cmd = "opam" } as r)) -> system_errors_of_r r
  | Process (Exited 3,
             ({ r_cmd = "opam" } as r)) -> solver_errors_of_r r
  | Process (Exited 4,
             ({ r_cmd = "opam" } as r)) -> build_errors_of_r r
  | Process (Exited 66,
             ({ r_cmd = "opam" } as r)) -> other_errors_of_r r
  | Process ((Exited 128 | Stopped _ | Signaled _),
             ({ r_cmd = "git" } as r))  -> system_errors_of_r r
  | _                                   -> Multiple []
)

let error_of_exn = Repo.(function
  | ProcessError (status, r) -> Process (status, r)
  | exn -> Other (Sexplib.Sexp.to_string (sexp_of_exn exn),
                  if Printexc.backtrace_status ()
                  then "Backtrace:\n"^(Printexc.get_backtrace ())
                  else "No backtrace available.")
)

let bufs_of_error site = Repo.(function
  | Process (Exited code, r) ->
      (Printf.sprintf "%s\nOCAMLOT %s \"%s %s\" failed (%d) in %s\n"
         r.r_stderr site r.r_cmd (String.concat " " r.r_args) code
         (Time.duration_to_string r.r_duration), r.r_stdout)
  | Process (Stopped signum, r)
  | Process (Signaled signum, r) ->
      (Printf.sprintf "%s\nOCAMLOT %s \"%s %s\" terminated by signal %d in %s\n"
         r.r_stderr site r.r_cmd (String.concat " " r.r_args) signum
         (Time.duration_to_string r.r_duration), r.r_stdout)
  | Other (sexn, backtrace) ->
      (Printf.sprintf "OCAMLOT %s terminated by\n%s\n%s\n" site sexn backtrace,
       "")
)

let to_bufs = Repo.(function
  | { status = Passed r; duration } ->
      let facts = Printf.sprintf "OCAMLOT \"%s %s\" succeeded in %s\n"
        r.r_cmd (String.concat " " r.r_args)
        (Time.duration_to_string duration) in
      (facts^r.r_stderr, r.r_stdout)
  | { status = Failed (_, error); duration } ->
      bufs_of_error
        (Printf.sprintf "After %s Opam_task.run"
           (Time.duration_to_string duration))
        error
)

let die site exn =
  let err, out = bufs_of_error site (error_of_exn exn) in
  Printf.eprintf "stdout: %s\nstderr: %s\n%!" out err;
  exit 1

let string_of_system_error = function
  | No_space -> "storage exhausted"
  | Worker_is_root -> "worker running as root user"

let rec string_of_analysis = function
  | Solver None -> "no constraint solution"
  | Solver (Some (Unsatisfied_dep dep)) ->
      "unsatisfied dependency \""^dep^"\""
  | Solver (Some Incompatible) -> "incompatible"
  | Build Error_for_warn -> "error-enabled warnings"
  | Build (Compilation (f, l, c)) ->
     "compilation error at \""^f^"\", line "^l^
     (if c <> "" then ", characters "^c else "" )
  | Meta (Checksum (_, _, _)) -> "invalid checksum"
  | Ext_dep (Opam_depext info) -> "unknown opam-depext error: "^info
  | Ext_dep (Pkg_config pkg) -> "no external dependency \""^pkg^"\""
  | Ext_dep (Pkg_config_constraint (pkg, bound)) ->
      "external dependency \""^pkg^"\" must be \""^bound^"\""
  | Ext_dep (Header header) -> "no external dependency \""^header^".h\""
  | Ext_dep (Command command) -> "no external dependency command \""^command^"\""
  | Ext_dep (C_libs exts) -> "no external dependencies: "
      ^(String.concat ", " (List.map (fun ext -> "\""^ext^"\"") exts))
  | Ext_dep (Wrong_depext (pkg, info)) -> "wrong package \""^pkg^"\" for "^info
  | Meta (Ocamlfind_dep dep) -> "missing ocamlfind dependency \""^dep^"\""
  | Meta (Findlib_constraint (pkg, bound)) ->
      "missing findlib constraint \""^pkg^" "^bound^"\""
  | System sys_err -> "system error: "^(string_of_system_error sys_err)
  | Transient (Broken_link uri)
  | Transient (Opam_metadata uri) ->
    "could not retrieve <"^(Uri.to_string uri)^">"
  | Dep (dep, subanalysis) ->
    Printf.sprintf "error in dependency \"%s\" (%s)"
      dep (string_of_analysis subanalysis)
  | Multiple [] -> "unknown"
  | Multiple al -> String.concat ", " (List.map string_of_analysis al)

let string_of_status = function
  | Passed _ -> "PASS"
  | Failed (a,_) -> Printf.sprintf "FAIL (%s)" (string_of_analysis a)

