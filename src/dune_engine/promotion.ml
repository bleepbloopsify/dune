open Import

let staging_area = Path.Build.relative Path.Build.root ".promotion-staging"

module Promote_annot = struct
  type payload =
    { in_source : Path.Source.t
    ; in_build : Path.Build.t
    }

  let to_dyn { in_source; in_build } =
    let open Dyn.Encoder in
    record
      [ ("in_source", Path.Source.to_dyn in_source)
      ; ("in_build", Path.Build.to_dyn in_build)
      ]
end

module Annot = struct
  type t = Promote_annot.payload =
    { in_source : Path.Source.t
    ; in_build : Path.Build.t
    }

  include User_error.Annot.Make (Promote_annot)
end

module File = struct
  type t =
    { src : Path.Build.t
    ; staging : Path.Build.t option
    ; dst : Path.Source.t
    }

  let in_staging_area source = Path.Build.append_source staging_area source

  let to_dyn { src; staging; dst } =
    let open Dyn.Encoder in
    record
      [ ("src", Path.Build.to_dyn src)
      ; ("staging", option Path.Build.to_dyn staging)
      ; ("dst", Path.Source.to_dyn dst)
      ]

  let db : t list ref = ref []

  let register_dep ~source_file ~correction_file =
    db :=
      { src = snd (Path.Build.split_sandbox_root correction_file)
      ; staging = None
      ; dst = source_file
      }
      :: !db

  let register_intermediate ~source_file ~correction_file =
    let staging = in_staging_area source_file in
    Path.mkdir_p (Path.build (Option.value_exn (Path.Build.parent staging)));
    Unix.rename
      (Path.Build.to_string correction_file)
      (Path.Build.to_string staging);
    let src = snd (Path.Build.split_sandbox_root correction_file) in
    db := { src; staging = Some staging; dst = source_file } :: !db

  let do_promote ~correction_file ~dst =
    Path.unlink_no_err (Path.source dst);
    let chmod perms = perms lor 0o200 in
    Io.copy_file ~chmod
      ~src:(Path.build correction_file)
      ~dst:(Path.source dst) ()

  let promote { src; staging; dst } =
    let correction_file = Option.value staging ~default:src in
    let correction_exists =
      Path.Untracked.exists (Path.build correction_file)
    in
    Console.print
      [ Pp.box ~indent:2
          (if correction_exists then
            Pp.textf "Promoting %s to %s."
              (Path.to_string_maybe_quoted (Path.build src))
              (Path.Source.to_string_maybe_quoted dst)
          else
            Pp.textf "Skipping promotion of %s to %s as the %s is missing."
              (Path.to_string_maybe_quoted (Path.build src))
              (Path.Source.to_string_maybe_quoted dst)
              (match staging with
              | None -> "file"
              | Some staging ->
                Format.sprintf "staging file (%s)"
                  (Path.to_string_maybe_quoted (Path.build staging))))
      ];
    if correction_exists then do_promote ~correction_file ~dst
end

let clear_cache () = File.db := []

let () = Hooks.End_of_build.always clear_cache

module P = Persistent.Make (struct
  type t = File.t list

  let name = "TO-PROMOTE"

  let version = 2

  let to_dyn = Dyn.Encoder.list File.to_dyn
end)

let db_file = Path.relative Path.build_dir ".to-promote"

let dump_db db =
  if Path.build_dir_exists () then
    match db with
    | [] -> if Path.Untracked.exists db_file then Path.unlink_no_err db_file
    | l -> P.dump db_file l

let load_db () = Option.value ~default:[] (P.load db_file)

let group_by_targets db =
  List.map db ~f:(fun { File.src; staging; dst } -> (dst, (src, staging)))
  |> Path.Source.Map.of_list_multi
  (* Sort the list of possible sources for deterministic behavior *)
  |> Path.Source.Map.map
       ~f:(List.sort ~compare:(fun (x, _) (y, _) -> Path.Build.compare x y))

type files_to_promote =
  | All
  | These of Path.Source.t list * (Path.Source.t -> unit)

let do_promote db files_to_promote =
  let by_targets = group_by_targets db in
  let promote_one dst srcs =
    match srcs with
    | [] -> assert false
    | (src, staging) :: others ->
      (* We used to remove promoted files from the digest cache, to force Dune
         to redigest them on the next run. We did this because on OSX [mtime] is
         not precise enough and if a file is modified and promoted quickly, it
         looked like it hadn't changed even though it might have.

         aalekseyev: This is probably unnecessary now, depending on when
         [do_promote] runs (before or after [invalidate_cached_timestamps]).

         amokhov: I removed this logic. In the current state of the world, files
         in the build directory should be redigested automatically (plus we do
         not promote into the build directory anyway), and source digests should
         be correctly invalidated via [fs_memo]. If that doesn't happen, we
         should fix [fs_memo] instead of manually resetting the caches here. *)
      File.promote { src; staging; dst };
      List.iter others ~f:(fun (path, _staging) ->
          Console.print
            [ Pp.textf " -> ignored %s."
                (Path.to_string_maybe_quoted (Path.build path))
            ; Pp.newline
            ])
  in
  match files_to_promote with
  | All ->
    Path.Source.Map.iteri by_targets ~f:promote_one;
    []
  | These (files, on_missing) ->
    let files = Path.Source.Set.of_list files |> Path.Source.Set.to_list in
    let by_targets =
      List.fold_left files ~init:by_targets ~f:(fun map fn ->
          match Path.Source.Map.find by_targets fn with
          | None ->
            on_missing fn;
            map
          | Some srcs ->
            promote_one fn srcs;
            Path.Source.Map.remove by_targets fn)
    in
    Path.Source.Map.to_list by_targets
    |> List.concat_map ~f:(fun (dst, srcs) ->
           List.map srcs ~f:(fun (src, staging) -> { File.src; staging; dst }))

let finalize () =
  let db =
    match !Clflags.promote with
    | Some Automatically -> do_promote !File.db All
    | Some Never
    | None ->
      !File.db
  in
  dump_db db

let promote_files_registered_in_last_run files_to_promote =
  let db = load_db () in
  let db = do_promote db files_to_promote in
  dump_db db
