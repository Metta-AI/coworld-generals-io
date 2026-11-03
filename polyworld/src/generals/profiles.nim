const
  ProfileTracePath* {.strdefine.} = ""
  ProfileFrames* {.intdefine.} = 100
  ProfileStart* {.intdefine.} = 0
  ProfileEnabled* = ProfileTracePath.len > 0 or defined(profile)
  RuntimeTracePath* = "out/fluffy-generals.json"

when ProfileEnabled:
  import
    std/[macros, os, osproc],
    fluffy/measure as fluffy,
    common

  static:
    doAssert fluffy.MaxTraceEvents == 10_000

  var
    profileStarted = false
    profileDumped = false
    profileInteractive = false
    profilePath = ""
    viewer: Process

  proc tracePush(name: string) {.raises: [].} =
    ## Preserves measured procedure effects around guarded Fluffy lookups.
    {.cast(raises: []).}:
      fluffy.measurePush(name)

  proc tracePop() {.raises: [].} =
    ## Closes the corresponding Fluffy section without changing game effects.
    {.cast(raises: []).}:
      fluffy.measurePop()

  macro measure*(fn: untyped): untyped =
    ## Instruments a procedure only when a profiling build is requested.
    let name = fn[0].repr
    fn[6].insert 0, quote do:
      tracePush(`name`)
      defer:
        tracePop()
    fn

  proc ensureProfileDir() =
    ## Creates the output directory and maps filesystem errors to the game.
    try:
      let directory = profilePath.parentDir()
      if directory.len > 0:
        createDir(directory)
    except OSError as error:
      raise newException(GeneralsError, error.msg)

  proc startProfileTrace*() =
    ## Starts one bounded deterministic capture at the configured path.
    if profileStarted or profileDumped:
      return
    profilePath =
      if ProfileTracePath.len > 0:
        ProfileTracePath
      else:
        RuntimeTracePath
    ensureProfileDir()
    profileStarted = true
    fluffy.startTrace()

  proc finishProfileTrace*() =
    ## Writes the capture once while retaining Fluffy's 10,000-event cap.
    if not profileStarted:
      return
    profileStarted = false
    profileDumped = true
    fluffy.endTrace()
    ensureProfileDir()
    try:
      fluffy.dumpMeasures(profilePath)
    except IOError as error:
      raise newException(GeneralsError, error.msg)

  proc profileShouldDump*(frames: int): bool =
    ## Checks the deterministic frame budget without truncating F2 sessions.
    profileStarted and not profileInteractive and
      ProfileFrames > 0 and frames >= ProfileFrames

  proc viewerPath(): string =
    ## Finds a configured Fluffy source or the pinned dependency checkout.
    const Root = currentSourcePath().parentDir.parentDir.parentDir
    let configured = getEnv("FLUFFY_VIEWER")
    for path in [
      configured,
      Root / ".deps/fluffy/src/fluffy.nim",
      Root.parentDir / "fluffy/src/fluffy.nim"
    ]:
      if path.len > 0 and fileExists(path):
        return path.absolutePath()

  proc closeProfileViewer*() =
    ## Releases the optional viewer process when the game closes.
    if viewer.isNil:
      return
    try:
      if viewer.running():
        viewer.terminate()
      discard viewer.waitForExit()
      viewer.close()
      viewer = nil
    except OSError, IOError:
      raise newException(GeneralsError, getCurrentExceptionMsg())

  proc openProfileViewer() =
    ## Opens Fluffy beside the game without leaving unbounded child processes.
    let path = viewerPath()
    if path.len == 0:
      echo "Fluffy viewer not found. Set FLUFFY_VIEWER to src/fluffy.nim."
      echo "Trace: ", profilePath.absolutePath()
      return
    try:
      if not viewer.isNil:
        if viewer.running():
          echo "Fluffy is open. Press F5 in Fluffy to reload the trace."
          return
        discard viewer.waitForExit()
        viewer.close()
      let
        executable = profilePath.absolutePath().parentDir /
          "fluffy-viewer".addFileExt(ExeExt)
        compiler = startProcess(
          "nim",
          workingDir = path.parentDir.parentDir,
          args = ["c", "-d:release", "--out:" & executable, path],
          options = {poUsePath, poParentStreams}
        )
      let status = compiler.waitForExit()
      compiler.close()
      if status != 0:
        raise newException(GeneralsError, "Cannot compile the Fluffy viewer.")
      viewer = startProcess(
        executable,
        workingDir = path.parentDir.parentDir,
        args = [profilePath.absolutePath()],
        options = {poParentStreams}
      )
    except OSError, IOError:
      raise newException(GeneralsError, getCurrentExceptionMsg())

  proc toggleProfileTrace*() =
    ## Starts or writes an interactive capture and opens its Fluffy viewer.
    if profileStarted:
      finishProfileTrace()
      if fileExists(profilePath):
        openProfileViewer()
    else:
      profileDumped = false
      profileInteractive = true
      startProfileTrace()

  template profileBlock*(name: string, body: untyped) =
    ## Measures a named section while a capture is active.
    tracePush(name)
    try:
      body
    finally:
      tracePop()
else:
  macro measure*(fn: untyped): untyped =
    ## Removes procedure instrumentation from ordinary builds.
    fn

  proc startProfileTrace*() =
    ## Leaves tracing disabled in ordinary builds.
    discard

  proc finishProfileTrace*() =
    ## Leaves tracing disabled in ordinary builds.
    discard

  proc profileShouldDump*(frames: int): bool =
    ## Leaves ordinary frame processing unchanged.
    false

  proc toggleProfileTrace*() =
    ## Explains how to enable the optional interactive profiler.
    echo "Build with -d:profile to capture a Fluffy trace with F2."

  proc closeProfileViewer*() =
    ## Leaves ordinary process cleanup unchanged.
    discard

  template profileBlock*(name: string, body: untyped) =
    ## Runs a named section without profiling overhead.
    body
