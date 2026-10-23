# Building and testing on the PC: `pc`

When `pc` is on PATH, this VPS is paired with the user's PC. Folders synced from the PC
(Mutagen, same path on both machines) are edited here as usual; anything that needs the PC's
toolchain or its heavy files (ISO/ROM, build output, disassembly projects: the folder's
`.femme-ignore` lists what stays there) runs on the PC with `pc <command>`, from the same
folder. `pc` flushes the sync both ways around the command, so the PC builds what was just
edited here and the results come back.

- `pc make`, `pc 'make && ./check.sh'`: one argument is a shell line, several are passed as is.
- Edit, read, grep and git here. Use `pc` for building, running, testing and for reading files
  that are not synced. Never copy heavy files to the VPS.
- `pc true` says whether the current folder is shared; if not, ask the user to run
  `sh sync-dir.sh <dir>` from the FEMME checkout on the PC.
- "laptop not linked" means the PC is asleep or away: keep editing, tell the user what is
  waiting on the PC, and do not retry in a loop.
