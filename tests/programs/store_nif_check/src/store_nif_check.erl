%% The NIFs of the store as native NIF objects (docs/NIFS.md): vix
%% (libvips, glib, C++ and Rust), rusty_csv (Rust, thread-local data), and
%% ex_pdfium (PDFium, C++). scripts/nif_object.sh makes priv/LIB.ARCH.o
%% from the part of each NIF; tests/run.sh puts them in priv/ before the
%% build. For each NIF with an object for this CPU, main/1 makes its
%% module (the module of the package), loads the object, and runs the
%% checks. It writes "store_nif_check: LIB ok" for each, and then
%% "store_nif_check: all N passed".
-module(store_nif_check).
-export([main/1]).

-define(VIX, 'Elixir.Vix.Nif').
-define(CSV, 'Elixir.RustyCSV.Native').
-define(PDF, 'Elixir.ExPdfium.Native').

main(_) ->
    Nifs = [{"vix", ?VIX, #{nif_logger_level => warning}, fun vix/0},
            {"rustycsv", ?CSV, 0, fun csv/0},
            {"ex_pdfium", ?PDF, 0, fun pdf/0}],
    Arch = case erlang:system_info(system_architecture) of
               "aarch64" ++ _ -> "aarch64";
               _ -> "x86_64"
           end,
    Results = [check(Lib, Mod, Info, Check, Arch) || {Lib, Mod, Info, Check} <- Nifs],
    case [R || R <- Results, R =:= failed] of
        [] ->
            N = length([R || R <- Results, R =:= ok]),
            io:format("store_nif_check: all ~b passed~n", [N]);
        Failed ->
            io:format("store_nif_check: ~b failed~n", [length(Failed)]),
            erlang:halt(1)
    end.

check(Lib, Mod, Info, Check, Arch) ->
    Path = filename:join(code:priv_dir(store_nif_check), Lib),
    case filelib:is_regular(Path ++ "." ++ Arch ++ ".o") of
        false ->
            io:format("store_nif_check: ~s not in priv~n", [Lib]),
            skipped;
        true ->
            try
                {T, ok} = timer:tc(fun() -> load(Mod, funs(Lib), Path, Info) end),
                io:format("store_nif_check: ~s loads in ~b ms~n", [Lib, T div 1000]),
                Check(),
                io:format("store_nif_check: ~s ok~n", [Lib]),
                ok
            catch
                Class:Reason:Stack ->
                    io:format("store_nif_check: ~s failed: ~P~n  ~P~n",
                              [Lib, {Class, Reason}, 20, Stack, 20]),
                    failed
            end
    end.

%% The module of the package, with a function for each NIF, and
%% load_nif/2 of the object.
load(Mod, Funs, Path, Info) ->
    L = 1,
    Init = {function, L, '$init', 2,
            [{clause, L, [{var, L, 'P'}, {var, L, 'I'}], [],
              [{call, L, {remote, L, {atom, L, erlang}, {atom, L, load_nif}},
                [{var, L, 'P'}, {var, L, 'I'}]}]}]},
    Stubs = [{function, L, F, A,
              [{clause, L, [{var, L, list_to_atom("V" ++ integer_to_list(I))}
                            || I <- lists:seq(1, A)], [],
                [{call, L, {remote, L, {atom, L, erlang}, {atom, L, nif_error}},
                  [{atom, L, not_loaded}]}]}]} || {F, A} <- Funs],
    Forms = [{attribute, L, module, Mod},
             {attribute, L, export, [{'$init', 2} | Funs]},
             {attribute, L, nifs, Funs}, Init | Stubs],
    {ok, Mod, Bin} = compile:forms(Forms, [binary]),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Bin),
    Mod:'$init'(Path, Info).

%% vix 0.42.0 (libvips 8.18): encode and decode each format of the part,
%% resize, thumbnail, an SVG, a bad image, and eight processes.
vix() ->
    %% The janitor of vix (Vix.Nif.Janitor): a resource destructor sends
    %% it each object, and it unrefs the object in a new process.
    case whereis('Elixir.Vix.Nif.Janitor') of
        undefined -> register('Elixir.Vix.Nif.Janitor', spawn(fun janitor/0));
        _ -> ok
    end,
    {8, _, _} = ?VIX:nif_vips_version(),
    W = 640, H = 480,
    Px = << <<(X rem 256), (Y rem 256), ((X + Y) rem 256)>>
            || Y <- lists:seq(0, H - 1), X <- lists:seq(0, W - 1) >>,
    {ok, Img} = ?VIX:nif_image_new_from_binary(Px, W, H, 3, 0),
    "640x480x3" = size_of(Img),
    {ok, Jpg} = ?VIX:nif_image_write_to_buffer(Img, <<".jpg[Q=90]">>),
    Back = load(Jpg),
    "640x480x3" = size_of(Back),
    {ok, Avg} = call(<<"avg">>, [{<<"in">>, Back}], <<"out">>),
    true = abs(Avg - 121.0) < 2.0,
    {ok, Small} = call(<<"resize">>, [{<<"in">>, Back}, {<<"scale">>, 0.25}], <<"out">>),
    "160x120x3" = size_of(Small),
    {ok, Raw} = ?VIX:nif_image_write_to_binary(Small),
    57600 = byte_size(Raw),
    [begin
         {ok, Enc} = ?VIX:nif_image_write_to_buffer(Small, Suffix),
         "160x120x3" = size_of(load(Enc))
     end || Suffix <- [<<".png">>, <<".webp">>, <<".avif">>, <<".gif">>]],
    {ok, Thumb} = call(<<"thumbnail_buffer">>,
                       [{<<"buffer">>, ?VIX:nif_vips_blob(Jpg)}, {<<"width">>, 100}], <<"out">>),
    "100x75x3" = size_of(Thumb),
    Svg = <<"<svg xmlns='http://www.w3.org/2000/svg' width='160' height='120'>"
            "<rect x='10' y='10' width='140' height='100' fill='#c03020'/></svg>">>,
    "160x120x4" = size_of(load(Svg)),
    {error, _} = ?VIX:nif_foreign_find_load_buffer(<<"not an image">>),
    ["640x480x3"] = in_processes(fun() ->
                                         {ok, J} = ?VIX:nif_image_write_to_buffer(Img, <<".jpg">>),
                                         size_of(load(J))
                                 end).

janitor() ->
    receive
        {unref_gobject, T} -> spawn(fun() -> ok = ?VIX:nif_g_object_unref(T) end);
        {unref_gboxed, T} -> spawn(fun() -> ok = ?VIX:nif_g_boxed_unref(T) end)
    end,
    janitor().

load(Bytes) ->
    {ok, Loader} = ?VIX:nif_foreign_find_load_buffer(Bytes),
    {ok, Img} = call(Loader, [{<<"buffer">>, ?VIX:nif_vips_blob(Bytes)}], <<"out">>),
    Img.

call(Name, Args, Out) ->
    {ok, Outs} = ?VIX:nif_vips_operation_call(Name, Args),
    {Out, Value} = lists:keyfind(Out, 1, Outs),
    {ok, Value}.

size_of(Img) ->
    [W, H, B] = [begin {ok, {_, V}} = ?VIX:nif_image_get_header(Img, F), V end
                 || F <- [<<"width">>, <<"height">>, <<"bands">>]],
    lists:flatten(io_lib:format("~bx~bx~b", [W, H, B])).

%% rusty_csv 0.4.6: a parse, and the parallel parse in eight processes.
csv() ->
    [[<<"a">>, <<"b">>], [<<"1">>, <<"2">>], [<<"3">>, <<"x,y">>]] =
        ?CSV:parse_string(<<"a,b\n1,2\n3,\"x,y\"\n">>),
    Big = iolist_to_binary([[integer_to_binary(I), ",name", integer_to_binary(I), ",",
                             integer_to_binary(I * 7), "\n"] || I <- lists:seq(1, 100000)]),
    Rows = ?CSV:parse_string(Big),
    100000 = length(Rows),
    Rows = ?CSV:parse_string_parallel(Big),
    [true] = in_processes(fun() -> ?CSV:parse_string_parallel(Big) =:= Rows end).

%% ex_pdfium 0.6.0 (PDFium): make, draw, save, open, read the text,
%% render, a bad document, and eight processes.
pdf() ->
    {ok, D} = ?PDF:document_new(),
    [{ok, _} = ?PDF:document_add_page(D, 595.28, 841.89, -1) || _ <- lists:seq(1, 3)],
    Text = <<"Hello from a native NIF object">>,
    {ok, _} = ?PDF:document_draw_text(D, 1, 72.0, 760.0, Text, <<"helvetica">>, 24.0, {0, 0, 0, 255}),
    {ok, <<"%PDF-", _/binary>> = Bytes} = ?PDF:document_save(D),
    {ok, D2} = ?PDF:document_open({binary, Bytes}, nil),
    {ok, 3} = ?PDF:document_page_count(D2),
    {ok, Read} = ?PDF:document_extract_text(D2, 1),
    {_, _} = binary:match(Read, <<"native NIF">>),
    {ok, {Data, PW, PH, _, _}} = ?PDF:document_render_page(D2, 1, #{dpi => 72}),
    true = PW > 500 andalso PH > 700 andalso byte_size(Data) >= PW * PH * 3,
    {error, _} = ?PDF:document_open({binary, <<"%PDF-1.7 not a document">>}, nil),
    [true] = in_processes(fun() ->
                                  {ok, Dx} = ?PDF:document_open({binary, Bytes}, nil),
                                  {ok, {_, Wx, _, _, _}} = ?PDF:document_render_page(Dx, 0, #{dpi => 50}),
                                  Wx > 300
                          end).

%% The results of F in eight processes at the same time, without
%% duplicates.
in_processes(F) ->
    Self = self(),
    Pids = [spawn(fun() -> Self ! {self(), try F() catch C:R -> {C, R} end} end)
            || _ <- lists:seq(1, 8)],
    lists:usort([receive {P, R} -> R after 120000 -> timeout end || P <- Pids]).

%% The NIF functions of each library, as load_nif/2 needs them: the
%% versions of the parts of scripts/steps.sh (hex_nif_recipe).
funs("vix") ->
    [{nif_double_array, 1}, {nif_foreign_find_load, 1},
      {nif_foreign_find_load_buffer, 1}, {nif_foreign_find_load_source, 1},
      {nif_foreign_find_save, 1}, {nif_foreign_find_save_buffer, 1},
      {nif_foreign_find_save_target, 1}, {nif_foreign_get_loader_suffixes, 0},
      {nif_foreign_get_suffixes, 0}, {nif_g_boxed_unref, 1},
      {nif_g_object_type_name, 1}, {nif_g_object_unref, 1},
      {nif_g_type_from_instance, 1}, {nif_g_type_name, 1},
      {nif_image_array, 1}, {nif_image_copy_memory, 1},
      {nif_image_get_as_string, 2}, {nif_image_get_fields, 1},
      {nif_image_get_header, 2}, {nif_image_hasalpha, 1}, {nif_image_new, 0},
      {nif_image_new_from_binary, 5}, {nif_image_new_from_file, 1},
      {nif_image_new_from_image, 2}, {nif_image_new_from_source, 2},
      {nif_image_new_matrix_from_array, 5}, {nif_image_new_temp_file, 1},
      {nif_image_remove_metadata, 2}, {nif_image_set_metadata, 4},
      {nif_image_to_target, 3}, {nif_image_update_metadata, 3},
      {nif_image_write_area_to_binary, 2}, {nif_image_write_to_binary, 1},
      {nif_image_write_to_buffer, 2}, {nif_image_write_to_file, 2},
      {nif_int_array, 1}, {nif_interpolate_new, 1}, {nif_pipe_open, 1},
      {nif_read, 2}, {nif_source_new, 0}, {nif_target_new, 0},
      {nif_vips_blob, 1}, {nif_vips_blob_to_erl_binary, 1},
      {nif_vips_cache_get_max, 0}, {nif_vips_cache_get_max_files, 0},
      {nif_vips_cache_get_max_mem, 0}, {nif_vips_cache_set_max, 1},
      {nif_vips_cache_set_max_files, 1}, {nif_vips_cache_set_max_mem, 1},
      {nif_vips_concurrency_get, 0}, {nif_vips_concurrency_set, 1},
      {nif_vips_double_array_to_erl_list, 1}, {nif_vips_enum_list, 0},
      {nif_vips_flag_list, 0}, {nif_vips_image_array_to_erl_list, 1},
      {nif_vips_int_array_to_erl_list, 1}, {nif_vips_leak_set, 1},
      {nif_vips_nickname_find, 1}, {nif_vips_operation_call, 2},
      {nif_vips_operation_get_arguments, 1}, {nif_vips_operation_list, 0},
      {nif_vips_ref_string, 1}, {nif_vips_ref_string_to_erl_binary, 1},
      {nif_vips_shutdown, 0}, {nif_vips_tracked_get_mem, 0},
      {nif_vips_tracked_get_mem_highwater, 0}, {nif_vips_version, 0},
      {nif_write, 2}];
funs("rustycsv") ->
    [{encode_string, 7}, {encode_string_parallel, 7}, {get_rust_memory, 0},
      {get_rust_memory_peak, 0}, {parse_string, 1}, {parse_string_fast, 1},
      {parse_string_fast_with_config, 5}, {parse_string_indexed, 1},
      {parse_string_indexed_with_config, 5}, {parse_string_parallel, 1},
      {parse_string_parallel_with_config, 5}, {parse_string_with_config, 5},
      {parse_string_zero_copy, 1}, {parse_string_zero_copy_with_config, 5},
      {parse_to_maps, 8}, {parse_to_maps_parallel, 7},
      {reset_rust_memory_stats, 0}, {streaming_feed, 2},
      {streaming_finalize, 1}, {streaming_new, 0},
      {streaming_new_with_config, 4}, {streaming_next_rows, 2},
      {streaming_set_max_buffer, 2}, {streaming_status, 1}];
funs("ex_pdfium") ->
    [{document_add_free_text_annotation, 9},
      {document_add_link_annotation, 7}, {document_add_page, 4},
      {document_add_square_annotation, 8}, {document_add_text_annotation, 6},
      {document_annotations, 2}, {document_append, 2},
      {document_attachment_data, 2}, {document_attachments, 1},
      {document_close, 1}, {document_delete_annotation, 3},
      {document_delete_pages, 3}, {document_draw_circle, 8},
      {document_draw_image, 10}, {document_draw_line, 8},
      {document_draw_rectangle, 9}, {document_draw_text, 8},
      {document_extract_pages, 2}, {document_extract_text, 2},
      {document_extract_text_all, 1}, {document_flatten, 1},
      {document_flatten_page, 2}, {document_form_fields, 1},
      {document_form_type, 1}, {document_image_data, 3},
      {document_image_raw_data, 3}, {document_images, 2}, {document_links, 2},
      {document_metadata, 1}, {document_new, 0}, {document_open, 2},
      {document_outline, 1}, {document_page_count, 1}, {document_page_info, 2},
      {document_page_objects, 2}, {document_permissions, 1},
      {document_render_page, 3}, {document_rotate_page, 3}, {document_save, 1},
      {document_search_text, 5}, {document_signatures, 1},
      {document_text_chars, 3}, {document_text_segments, 2},
      {pdfium_version, 0}, {set_dynamic_lib_dir, 1}].
