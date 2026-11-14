exe :: "josh";

#run {
    w := compiler_create_workspace("josh");

    options := get_build_options(w);
    opts := set_options(*options); 
    set_build_options(opts, w);

    compiler_begin_intercept(w);
    
    add_build_file("main.jai", w);

    compiler_end_intercept(w);

    set_build_options_dc(.{ do_output = false });
}

set_options :: (opts: *Build_Options) -> Build_Options {
    args := opts.compile_time_command_line;    

    opts.output_type = .EXECUTABLE;
    opts.backend = .X64;
    opts.emit_debug_info = .NONE;

    opts.output_executable_name = exe;

    // so that it doesnt open a cmd prompt window when launching the exe
    #if OS == .WINDOWS {
        opts.additional_linker_arguments = .["/SUBSYSTEM:WINDOWS", "/ENTRY:mainCRTStartup"];
    }

    return opts;
}

#import "Basic";
#import "Compiler";

