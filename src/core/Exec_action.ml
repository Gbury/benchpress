
(** {1 Execute actions} *)

module Fmt = CCFormat
module E = CCResult
module T = Test
type 'a or_error = ('a, string) E.t

module Exec_run_provers : sig
  type t = Action.run_provers

  type expanded = {
    j: int;
    problems: Problem.t list;
    provers: Prover.t list;
    timeout: int;
    memory: int;
  }

  val expand : 
    ?j:int ->
    ?timeout:int ->
    ?memory:int ->
    ?interrupted:(unit -> bool) ->
    t -> expanded or_error

  val run :
    ?timestamp:float ->
    ?uuid:Uuidm.t ->
    ?on_start:(expanded -> unit) ->
    ?on_solve:(Test.result -> unit) ->
    ?on_done:(Test.top_result -> unit) ->
    ?interrupted:(unit -> bool) ->
    expanded ->
    Test.top_result or_error
  (** Run the given prover(s) on the given problem set, obtaining results
      after all the problems have been dealt with.
      @param on_solve called whenever a single problem is solved
      @param on_done called when the whole process is done
  *)
end = struct
  open E.Infix

  type t = Action.run_provers
  let (>?) a b = match a with None -> b | Some x -> x
  let (>??) a b = match a with None -> b | Some _ as x -> x

  type expanded = {
    j: int;
    problems: Problem.t list;
    provers: Prover.t list;
    timeout: int;
    memory: int;
  }

  let filter_regex_ = function
    | None -> (fun _ -> true)
    | Some re ->
      let re = Re.Perl.compile_pat re in
      (fun path -> Re.execp re path)

  (* turn a subdir into a list of problems *)
  let expand_subdir ?pattern ?(interrupted=fun _->false) (s:Subdir.t) : Problem.t list or_error =
    try
      let filter1 = filter_regex_ s.Subdir.inside.pattern in
      let filter2 = filter_regex_ pattern in
      let filter s = filter1 s && filter2 s in
      CCIO.File.walk_l s.Subdir.path
      |> CCList.filter_map
        (fun (kind,f) ->
           if interrupted() then failwith "interrupted";
           match kind with
           | `File when filter f -> Some f
           | _ -> None)
      |> Misc.Par_map.map_p ~j:3
        (fun path ->
           if interrupted() then failwith "interrupted";
           Problem.make_find_expect path ~expect:s.Subdir.inside.expect)
      |> E.flatten_l
    with e ->
      E.of_exn_trace e |> E.add_ctxf "expand_subdir of_dir %a" Subdir.pp s

  (* Expand options into concrete choices *)
  let expand ?j ?timeout ?memory ?interrupted (self:t) : expanded or_error =
    let j = j >?? self.j >? Misc.guess_cpu_count () in
    let timeout = timeout >?? self.timeout >? 60 in
    let memory = memory >?? self.memory >? 1_000 in
    E.map_l (expand_subdir ?interrupted) self.dirs >>= fun problems ->
    let problems = CCList.flatten problems in
    Ok { j; memory; timeout; problems; provers=self.provers; }

  let _nop _ = ()

  let run ?(timestamp=Unix.gettimeofday())
      ?(uuid=Misc.mk_uuid())
      ?(on_start=_nop) ?(on_solve = _nop) ?(on_done = _nop)
      ?(interrupted=fun _->false)
      (self:expanded) : _ E.t =
    let open E.Infix in
    let start = Unix.gettimeofday() in
    on_start self;
    (* build list of tasks *)
    let jobs =
      CCList.flat_map
        (fun pb -> List.map (fun prover -> prover,pb) self.provers)
        self.problems
    in
    (* run provers *)
    (* TODO: store results in DB as we go *)
    begin
      Misc.Par_map.map_p ~j:self.j
        (fun (prover,pb) ->
          if interrupted() then E.fail "interrupted"
          else (
            begin
              Run_prover_problem.run
                ~timeout:self.timeout ~memory:self.memory
                prover pb >|= fun result ->
              on_solve result; (* callback *)
              result
            end
            |> E.add_ctxf "(@[running :prover %a :on %a@])"
              Prover.pp_name prover Problem.pp pb)
        )
        jobs
      |> E.flatten_l
    end
    >>= fun res_l ->
    if interrupted() then (
      Error "interrupted"
    ) else (
      let total_wall_time =  Unix.gettimeofday() -. start in
      let r = T.Top_result.make ~timestamp ~total_wall_time ~uuid res_l in
      E.iter on_done r;
      r
    )
end

module Progress_run_provers = struct
  type t = Run_prover_problem.job_res -> unit

  let nil _ = ()

  (* callback that prints a result *)
  let progress_dynamic len =
    let start = Unix.gettimeofday () in
    let count = ref 0 in
    fun _ ->
      let time_elapsed = Unix.gettimeofday () -. start in
      incr count;
      let len_bar = 50 in
      let bar = String.init len_bar
          (fun i -> if i * len <= len_bar * !count then '#' else '-') in
      let percent = if len=0 then 100. else (float_of_int !count *. 100.) /. float_of_int len in
      (* elapsed=(percent/100)*total, so total=elapsed*100/percent; eta=total-elapsed *)
      let eta = time_elapsed *. (100. -. percent) /. percent in
      Misc.synchronized
        (fun () ->
           Format.printf "... %5d/%d | %3.1f%% [%6s: %s] [eta %6s]@?"
             !count len percent (Misc.human_time time_elapsed) bar (Misc.human_time eta));
      if !count = len then (
        Misc.synchronized (fun() -> Format.printf "@.")
      )

  let progress ~w_prover ~w_pb ?(dyn=false) n : Run_prover_problem.job_res -> unit =
    let pp_bar = progress_dynamic n in
    (function res ->
       if dyn then output_string stdout Misc.reset_line;
       Run_prover_problem.pp_result_progress ~w_prover ~w_pb res;
       if dyn then pp_bar res;
       ())

  let make ?dyn (r:Exec_run_provers.expanded) : t =
    let len = List.length r.problems in
    let w_prover =
      List.fold_left (fun m p -> max m (String.length (Prover.name p)+1)) 0
        r.provers
      |> min 25
    and w_pb =
      List.fold_left (fun m pb -> max m (String.length pb.Problem.name+1)) 0 r.problems
      |> min 60
    in
    progress ~w_prover ~w_pb ?dyn (len * List.length r.provers)
end


let run ?interrupted (defs:Definitions.t) (a:Action.t) : unit or_error =
  Misc.err_with
    ~map_err:(Printf.sprintf "while running action: %s")
    (fun scope ->
      begin match a with
      | Action.Act_run_provers r ->
        let r_expanded =
          Exec_run_provers.expand ?interrupted
            ?j:(Definitions.option_j defs) r
          |> scope.unwrap
        in
        let on_solve = match Definitions.option_progress defs with
          | Some true ->
            Progress_run_provers.make ~dyn:true r_expanded
          | _ -> Progress_run_provers.nil
        in
        let res =
          Exec_run_provers.run ?interrupted ~on_solve
            ~timestamp:(Unix.gettimeofday()) r_expanded
          |> scope.unwrap
        in
        Format.printf "task done: %a@." Test.Top_result.pp_compact res;
        ()
      end)
