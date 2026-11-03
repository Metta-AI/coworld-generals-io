import std/[os, strutils]

const Root = currentSourcePath().parentDir

let
  defaultDependencies =
    if dirExists(Root / ".deps"):
      Root / ".deps"
    else:
      Root.parentDir
  dependencies = getEnv("POLYWORLD_DEPS", defaultDependencies)

switch("path", Root / "src")
for line in readFile(Root / "dependencies.lock").splitLines():
  let fields = line.splitWhitespace()
  if fields.len == 3:
    let directory = dependencies / fields[0]
    if dirExists(directory / "src"):
      switch("path", directory / "src")
    elif dirExists(directory):
      switch("path", directory)
switch("outdir", Root / "out")
switch("nimcache", Root / "out/cache")
switch("mm", "arc")
switch("define", "flatty64")
