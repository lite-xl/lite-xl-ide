## Build Pluign

The build plugin works on a set of *targets*, that are either specified by a combuination of the project config and user config, or, if no targets are specified, inferred automatically from the installed build backends.

### Targets

Targets are the basis of the build plugin. Different build systems can co-exist simultaneously. By default, there are only three fields in a target:

* `name`: The identifier of the target.
* `binary`: The path to the primary executable.
* `backend`: Either the backend itself, or the name of a registered backend.
* `wd`: The working directory to run the `binary` in when executed.
* `run`: The command necessary to execute this target. If blank, will execute `binary`.

### Backends

Backends **should** supply the following methods:

* `build(target, callback)`: Builds the specified target.
* `clean(target, callback)`: Cleans the specified target.

Backends **can** supply the following methods:

* `infer()`: Called in a coroutine; returns the list of targets that this backend supports for this project.
* `priority`: The order in which `infer` is called, so build systems can act as fallbacks. Default 0, sorting ascending.

#### make

The `make` backend engages with `Makefile`s. If a `Makefile` exists, by default, the backend will infer the "all" target, which will simply call `make` with no arguments.

#### shell

The `shell` backend engages with a file called `build.sh`. If a `build.sh` file exists, by default the backend will infer a `debug` target, which will call the `build.sh` file with `-g`, and a `release` target, which will call the build.sh file with no arguments.

#### meson

The `meson` backend engages with a `meson.build` file. If a `meson.build` file exists, by default will infer a `debug` target, which if the directory `build-debug` doesn't exist will create it, and call `meson setup build-debug`. It will then call `ninja -C build-debug`.

#### internal

If no other backend has engaged, internal will look for a `src` folder. If it finds it, it will automtatically compile every `*.c` or `*.cpp` file in there with standard build parameters.
