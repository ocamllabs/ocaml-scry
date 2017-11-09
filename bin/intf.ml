open Cmdliner
open Scry

let ext = Arg.(
  value & opt int (-1) & info ["exit"]
    ~doc:"the build exit with the code $(docv)" ~docv:"EXT")

let signal = Arg.(
  value & opt int (-1) & info ["signal"]
    ~doc:"signaled with the code $(docv)" ~docv:"SIG")

let stop = Arg.(
  value & opt int (-1) & info ["stop"]
    ~doc:"process stopped with the code $(docv)" ~docv:"STOP")

let path_out = Arg.(
  value & opt file  "" & info ["out"]
    ~doc:"file path to stdout of opam build to triage" ~docv:"STDOUT")

let path_err = Arg.(
  value & opt file "" & info ["err"]
    ~doc:"file path to stderr of opam build to triage" ~docv:"STDERR")

let files = Arg.(
  non_empty & pos_all file [] & info []
    ~doc:"files to be concanated for the analysis" ~docv:"FILE")

let triage ext signal stop files =
  let p_status = Repo.(
    if not (ext = (-1)) then Exited ext
    else if not (signal = (-1)) then Signaled signal
    else if not (stop = (-1)) then Stopped stop
    else Exited (-1) (* no rc info from cmd *)) in
  let r =
    let buf = Buffer.create 512 in
    let string_of_path p =
      if p = "" then ""
      else begin
          let ic = open_in p in
          Buffer.clear buf;
          Buffer.add_channel buf ic (in_channel_length ic);
          Buffer.contents buf end in
    let str_to_analyze = String.concat "\n" (List.map string_of_path files) in
    Repo.({ r_cmd = "opam"; r_args = []; r_env = [||]; r_cwd = "";
            r_duration = Time.min;
            r_stdout = str_to_analyze;
            r_stderr = str_to_analyze; }) in
  let error = Result.error_of_exn (Repo.ProcessError (p_status, r)) in
  let status = Result.(Failed (analyze_all error, error)) in
  print_endline (Result.string_of_status status)

let scry_cmd =
  Term.(pure triage $ ext $ signal $ stop $ files),
  Term.info "scry" ~doc:"analyze build results"

let () = match Term.eval scry_cmd with `Error _ -> exit 1 | _ -> exit 0
