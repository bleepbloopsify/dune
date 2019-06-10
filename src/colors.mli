open! Stdune

val colorize : key:string -> string -> string

(** [Env.initial] extended with variables to force a few tools to
    print colors *)
val setup_env_for_colors : Env.t -> Env.t

(** Strip colors in [not (Lazy.force Ansi_color.stderr_supports_colors)] *)
val strip_colors_for_stderr : string -> string

(** Enable the interpretation of color tags for [Format.err_formatter] *)
val setup_err_formatter_colors : unit -> unit

type styles

val output_filename : styles

val command_success : styles

val command_error : styles

val apply_string : styles -> string -> string
