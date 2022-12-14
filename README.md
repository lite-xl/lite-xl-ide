# lite-xl IDE

[`lite-xl`](https://github.com/lite-xl/lite-xl) is a light-weight extensible text editor.

`lite-xl-ide` aims to be a suite a plugins for `lite-xl` that can turn it into a high-performance C/C++ IDE with minimal fuss.

## Quickstart

To install, you can use [`lpm`](https://github.com/adamharrison/lite-xl-plugin-manager):

```bash
lpm add https://github.com/adamharrison/lite-xl-ide.git && lpm install ide
```

If you want to just try it out, you can always use `run` to try it in a new lite bottle:

```bash
lpm add https://github.com/adamharrison/lite-xl-ide.git && lpm run ide
```

Alternatively, if you don't have `lpm`, or don't want it, you can always pull the repository manually with `git`
and simply copy the entire set of plugins into lite's plugin directory.

```bash
git clone https://github.com/adamharrison/lite-xl-ide.git && cp -R lite-xl-ide/plugins ~/.config/lite-xl-/plugins
```

## Plugins

### Build

The build plugin is a flexible build system. It can be configured to either use `make`, or, it can take over entirely
and run all the compile commands directly.

* Support for `make`.
* Support for internal building if configured with an appropriate compiler frontend. (`gcc` or `clang`).

#### TODO

* Make it so that the build drawer has a layout that allows it to sit at bottom, almost completely compressed, only showing thet title (which contains the build status) on successful builds.

### Debugger

The debugger plugin acts as a front-end to `gdb`.

* Allows placing of breakpoints by clicking in the gutter.
* Allows all normal debugging control operations: step, step over, step up, continue, break, quit.
* Allows watching variables by hovering over the appropriate symbol during debugging.
* Allows traversing the callstack when stopped.

#### TODO

* Allows watching variables by adding them to a watchlist.
* Allows adding hovered watched to watchlist with right click context menu.
* Make windows look nicer.
* Add in color rect to the debugger status.

### LSP

Full support for LSP through @jgmdev's [wonderful plugin](https://github.com/lite-xl/lite-xl-lsp), included in this manifest.

#### TODO

* Bundle a statically compiled ccls with LSP, and configure it through the ide plugin.

### Git

Full support for git, again through @jgmdev's [VCS plugin](https://github.com/lite-xl/lite-xl-plugins).

* Bundle a statically compiled git for vcs.
