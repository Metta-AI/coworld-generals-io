let
  webProject = Root
  webOutput = absolutePath(
    getEnv("GENERALS_WEB", webProject / "out/web")
  )
  webShell = webOutput / "shell.html"
mkDir(webOutput)
writeFile(
  webShell,
  readFile(dependencies / "polyworld/src/polyworld/replay.html")
    .replace("<title>Polyworld replay</title>", "<title>Generals Replay</title>")
    .replace("<title>Polyworld</title>", "<title>Generals Replay</title>")
    .replace("Loading replay viewer…", "Loading Generals replay…")
    .replace("Loading game…", "Loading Generals replay…")
)
switch("nimcache", webOutput / "nimcache")
switch("out", webOutput / "generals.html")
switch("threads", "off")
switch("os", "linux")
switch("cpu", "wasm32")
switch("cc", "clang")
switch("clang.exe", "emcc")
switch("clang.linkerexe", "emcc")
switch("mm", "arc")
switch("exceptions", "goto")
switch("define", "noSignalHandler")
switch("define", "noAutoGLerrorCheck")
switch(
  "passL",
  "-O3 --preload-file " & quoteShell(webProject / "assets" & "@/assets") &
    " --shell-file " & quoteShell(webShell)
)
switch(
  "passL",
  "-s ASYNCIFY -s FETCH -s USE_WEBGL2=1 " &
    "-s MAX_WEBGL_VERSION=2 -s MIN_WEBGL_VERSION=2 -s FULL_ES3=1 " &
    "-s GL_ENABLE_GET_PROC_ADDRESS=1 -s ALLOW_MEMORY_GROWTH " &
    "-s STACK_SIZE=8388608 -s INITIAL_MEMORY=134217728 --profiling"
)
