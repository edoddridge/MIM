import ConfigParser as par
import os
import os.path as p
import subprocess as sub
import time

from aronnax.core import fortran_file
from aronnax.core import interpret_requested_data
from aronnax.utils import working_directory

self_path = p.dirname(p.abspath(__file__))
root_path = p.dirname(self_path)

def simulate(work_dir=".", config_path="aronnax.conf", **options):
    """Main entry point for running an Aronnax simulation.

    A simulation occurs in the working directory given by the
    `work_dir` parameter, which defaults to the current directory when
    `simulate` is invoked.  The default arrangement of the working
    directory is as follows:

        - aronnax.conf - configuration file for that run
        - aronnax-merged.conf - file to save effective configuration, including
          effects of options passed to `simulate`. This file is automatically
          generated by merging the aronnax.conf file with the options passed to
          this function
        - parameters.in - relevant portions of aronnax-merged.conf in Fortran
          namelist format. Also generated automatically
        - input/ - subdirectory where Aronnax will save input field files
          in Fortran raw array format
        - output/ - subdirectory where Aronnax will save output field files
          in Fortran raw array format

    The process for a simulation is to

        1. Compute the configuration
        2. Recompile the Fortran core if necessary
        3. Save the computed configuration in aronnax-merged.conf
        4. Write raw-format input fields into input/
        5. Write parameters.in
        6. Execute the Fortran core, which writes progress messages
           to standard output and raw-format output fields into output/

    All the simulation parameters can be controlled from the
    configuration file aronnax.conf, and additionally can be
    overridden by passing them as optional arguments to `simulate`.

    Calling `simulate` directly provides one capability that cannot be
    accessed from the configuration file: custom idealized input
    generators.

    """
    config_file = p.join(work_dir, config_path)
    config = default_configuration()
    config.read(config_file)
    merge_config(config, options)
    with working_directory(work_dir):
        compile_core(config)
        # XXX Try to avoid overwriting the input configuration
        with open('aronnax-merged.conf', 'w') as f:
            config.write(f)
        # sub.check_call(["rm", "-rf", "output/"])
        sub.check_call(["mkdir", "-p", "output/"])
        sub.check_call(["mkdir", "-p", "checkpoints/"])
        with working_directory("input"):
            generate_input_data_files(config)
        generate_parameters_file(config)
        then = time.time()
        run_executable(config)
        core_run_time = time.time() - then
        sub.check_call(["rm", "-rf", "netcdf-output/"])
        sub.check_call(["mkdir", "-p", "netcdf-output/"])
        convert_output_to_netcdf(config)
        return core_run_time

def default_configuration():
    """Configuration defaults before parsing aronnax.conf.

    The configuration is represented as a ConfigParser.RawConfigParser instance."""
    config = par.RawConfigParser()
    for section in sections:
        config.add_section(section)
    config.set("executable", "valgrind", "False")
    config.set("executable", "perf", "False")
    config.optionxform = str
    return config

sections = ["executable", "numerics", "model", "pressure_solver", "sponge",
            "physics", "grid", "initial_conditions", "external_forcing"]

section_map = {
    "au"                   : "numerics",
    "ar"                   : "numerics",
    "kh"                   : "numerics",
    "kv"                   : "numerics",
    "botDrag"              : "numerics",
    "dt"                   : "numerics",
    "slip"                 : "numerics",
    "niter0"               : "numerics",
    "nTimeSteps"           : "numerics",
    "dumpFreq"             : "numerics",
    "avFreq"               : "numerics",
    "checkpointFreq"       : "numerics",
    "diagFreq"             : "numerics",
    "hmin"                 : "numerics",
    "maxits"               : "numerics",
    "eps"                  : "numerics",
    "freesurfFac"          : "numerics",
    "thickness_error"      : "numerics",
    "debug_level"          : "numerics",
    "hAdvecScheme"         : "numerics",
    "hmean"                : "model",
    "depthFile"            : "model",
    "H0"                   : "model",
    "RedGrav"              : "model",
    "nProcX"               : "pressure_solver",
    "nProcY"               : "pressure_solver",
    "spongeHTimeScaleFile" : "sponge",
    "spongeUTimeScaleFile" : "sponge",
    "spongeVTimeScaleFile" : "sponge",
    "spongeHFile"          : "sponge",
    "spongeUFile"          : "sponge",
    "spongeVFile"          : "sponge",
    "g_vec"                : "physics",
    "rho0"                 : "physics",
    "nx"                   : "grid",
    "ny"                   : "grid",
    "layers"               : "grid",
    "dx"                   : "grid",
    "dy"                   : "grid",
    "fUfile"               : "grid",
    "fVfile"               : "grid",
    "wetMaskFile"          : "grid",
    "initUfile"            : "initial_conditions",
    "initVfile"            : "initial_conditions",
    "initHfile"            : "initial_conditions",
    "initEtaFile"          : "initial_conditions",
    "zonalWindFile"        : "external_forcing",
    "meridionalWindFile"   : "external_forcing",
    "DumpWind"             : "external_forcing",
    "wind_mag_time_series_file" : "external_forcing",
    "RelativeWind"         : "external_forcing",
    "Cd"                   : "external_forcing",
    "exe"                  : "executable",
    "valgrind"             : "executable",
    "perf"                 : "executable",
}

def merge_config(config, options):
    """Merge the options given in the `options` dict into the RawConfigParser instance `config`.

    Mutates the given config instance."""
    for k, v in options.iteritems():
        if k in section_map:
            section = section_map[k]
            if not config.has_section(section):
                config.add_section(section)
            if v == True: v = "yes"
            if v == False: v = "no"
            config.set(section, k, v)
        else:
            raise Exception("Unrecognized option", k)

def compile_core(config):
    """Compile the Aronnax core, if needed."""
    core_name = config.get("executable", "exe")
    with working_directory(root_path):
        sub.check_call(["make", core_name])

data_types = {
    "depthFile"            : "2dT",
    "spongeHTimeScaleFile" : "3dT",
    "spongeUTimeScaleFile" : "3dU",
    "spongeVTimeScaleFile" : "3dV",
    "spongeHFile"          : "3dT",
    "spongeUFile"          : "3dU",
    "spongeVFile"          : "3dV",
    "fUfile"               : "2dU",
    "fVfile"               : "2dV",
    "wetMaskFile"          : "2dT",
    "initUfile"            : "3dU",
    "initVfile"            : "3dV",
    "initHfile"            : "3dT",
    "initEtaFile"          : "2dT",
    "zonalWindFile"        : "2dU",
    "meridionalWindFile"   : "2dV",
    "wind_mag_time_series_file" : "time",
}

def is_file_name_option(name):
    return name.endswith("File") or name.endswith("file")

def generate_input_data_files(config):
    for name, section in section_map.iteritems():
        if not is_file_name_option(name):
            continue
        if not config.has_option(section, name):
            continue
        requested_data = config.get(section, name)
        generated_data = interpret_requested_data(
            requested_data, data_types[name], config)
        if generated_data is not None:
            with fortran_file(name + '.bin', 'w') as f:
                f.write_record(generated_data)

def fortran_option_string(section, name, config):
    """Convert option values to strings that Fortran namelists will understand correctly.

    Two conversions are of interest: Booleans are rendered as
    .TRUE. or .FALSE., and options that are input fields are rendered
    as the file names where `generate_input_data_files` has written
    those data, or the Fortran empty string `''` if no file is written
    (which means the core should use its internal default).
    """
    if is_file_name_option(name):
        if config.has_option(section, name):
            # A file was generated
            return "'%s'" % (p.join("input", name + '.bin'),)
        else:
            return "''"
    if name in ["RedGrav", "DumpWind", "RelativeWind"]:
        if config.getboolean(section, name):
            return ".TRUE."
        else:
            return ".FALSE."
    else:
        if config.has_option(section, name):
            return config.get(section, name)
        else:
            return None

def generate_parameters_file(config):
    with open('parameters.in', 'w') as f:
        for section in config.sections():
            if section not in sections:
                raise Exception("Detected unexpected section name %s", section)
            f.write(' &')
            f.write(section.upper())
            f.write('\n')
            for (name, section1) in section_map.iteritems():
                if section1 != section: continue
                val = fortran_option_string(section, name, config)
                if val is not None:
                    f.write(' %s = %s,\n' % (name, val))
            f.write(' /\n')

def run_executable(config):
    """Run the compiled Fortran core, possibly in a test or debug regime."""
    core_name = config.get("executable", "exe")
    env = dict(os.environ, GFORTRAN_STDERR_UNIT="17")
    if config.getboolean("executable", "valgrind") \
       or 'ARONNAX_TEST_VALGRIND_ALL' in os.environ:
        assert not config.getboolean("executable", "perf")
        sub.check_call(["mpirun", "-np", "1",
            "valgrind", "--error-exitcode=5", p.join(root_path, core_name)],
            env=env)
    elif config.getboolean("executable", "perf"):
        perf_cmds = ["perf", "stat", "-e", "r530010", # "flops", on my CPU.
            "-e", "L1-dcache-loads", "-e", "L1-dcache-load-misses",
            "-e", "L1-dcache-stores", "-e", "L1-dcache-store-misses",
            "-e", "L1-icache-loads", "-e", "L1-icache-misses",
            "-e", "L1-dcache-prefetches",
            "-e", "branch-instructions", "-e", "branch-misses"]
        sub.check_call(perf_cmds + [p.join(root_path, core_name)], env=env)
    else:
        sub.check_call(["mpirun", "-np", "1", p.join(root_path, core_name)], env=env)

def convert_output_to_netcdf(config):
    # TODO Issue #30
    pass
