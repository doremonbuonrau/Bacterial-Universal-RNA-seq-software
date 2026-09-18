# Troubleshooting

## The GUI does not open

Open `Application/Logs/gui-startup.log` and `Application/Logs/launcher.log`. The native `Bacterial RNA Analysis.exe` launcher records startup failures and the GUI displays the failing message. If more detail is needed, run `Application/Maintenance/Debug Bacterial RNA Analysis.bat`. Keep the entire extracted folder together; the GUI requires `Application/App/method_catalog.json` and the icon assets.

## Windows warns about an unknown publisher

The launcher is a native EXE but is not commercially code-signed. Before extracting, right-click the downloaded ZIP, open Properties, select Unblock if present, and apply the change. If Windows SmartScreen still appears, verify the supplied SHA-256 checksum before selecting More info and Run anyway. Never disable Windows Security globally.

## WSL or Ubuntu is missing

Run `Application/Maintenance/Install or Repair.bat`. Complete any Windows restart and Ubuntu user-name prompt, then run the installer again. The bioinformatics backend requires Linux; the GUI itself remains a Windows application.

## A selected tool is missing

Page 4 checks the current project choices. Core tools come from `setup_linux.sh`. FADU and LongQC use the optional installer. Dorado is installed from Oxford Nanopore's official release because the binary depends on the system.

## The environment was ready before an update but now shows `python:openpyxl` missing

The existing bioinformatics tools are still installed. Version 1.9.1 added organized Excel result workbooks, so an environment created by an earlier build may lack OpenPyXL even though FastQC, aligners, samtools, featureCounts, deepTools, and MultiQC remain ready. Version 1.9.2 recognizes this exact upgrade case and offers a lightweight repair that installs only OpenPyXL into the existing `prok-rnaseq` environment. Accept **Repair update dependency**, let its console finish, then select **Check environment for read type** again. There is no need to reinstall WSL or Ubuntu. The full **Install or repair core** action also adds the package, preserves separately installed optional tools, and now reports failure if its final verification is not ready.

## The environment result is pink and shows only one letter

This was an output-decoding problem between `wsl.exe`, Windows PowerShell 5.1, and the WinForms result box. Some WSL errors arrived with embedded NUL or other control characters, causing text beginning with words such as `The` to appear as only `T`. The current build normalizes native output before displaying it and always shows the read type, WSL distribution, and exit code above the complete checker report. Replace the previous extracted application folder with the current build and select **Check environment for read type** again. If the result says **ACTION REQUIRED**, follow the detailed message or select **Install or repair core**.

## The run stopped

Read `OUTPUT/00_project/logs/pipeline.log` and `OUTPUT/.rnaseq_suite/state.json`. Correct the cause and run the same JSON project again with resume enabled. A checkpoint is reused only if the configuration hash matches and its outputs still exist.

## Strand contradiction

Do not ignore it automatically. Confirm the library kit with the sequencing provider. The attached company dUTP workflow normally corresponds to reverse-stranded counting. Correct the declared setting and rerun. Disabling strict strand checking is appropriate only when the assay is genuinely unstranded or the audit is too shallow.

## Low mapping rate

Check sample identity, reference strain/plasmids, rRNA depletion, contamination, adapter content, read quality, and annotation/reference contig names. Compare the independent audit BAM if dual alignment was selected. Do not merge the primary and audit BAMs.

## Safe stop

The GUI writes a stop request. The current external command is allowed to finish so it does not leave a truncated BAM. Completed checkpoints are preserved. Closing the main window during a run now gives three explicit choices: request a safe stop and close, close while leaving Linux processing active, or cancel and keep the GUI open. Final source/provenance loops also check the stop request.

## Final export remains at 97–99% or the log exceeds 100,000 lines

Version 1.9.0 could print every `files` and `paths_data.paths` entry from each Conda package metadata record. Large packages such as MathJax, NumPy, OpenJDK, MultiQC, and NetworkX could therefore create more than 500,000 lines after all scientific processing had already succeeded. The live Windows console then reread the whole growing file every 0.9 seconds, causing an extreme slowdown and preventing the Excel workbook and compact export from being finalized.

Version 1.9.1 replaces that loop with one bounded identity record per package. Detailed third-party package provenance is retained under `Intermediate files/Metadata/`, while the user-facing Excel workbooks stay focused on counts, QC, and alignment. The complete metadata-file SHA-256 preserves a fingerprint of the original record. All module live consoles show only their most recent 512 KiB while the persistent log remains complete. If resuming an interrupted run, the GUI archives the prior runtime logs before creating a clean current log; completed checkpoints remain available.

## Differential expression, GO, or network environment check fails

The downstream modules create the log before WSL starts and save it under `Application/Logs`. When the application folder is read-only, they use `%LOCALAPPDATA%\Bacterial RNA Analysis\Logs` instead. The error dialog shows a log path only after confirming that the file exists, and it includes the final messages from that log. The log records the selected WSL distribution, the exact command, WSL output, and the real exit code. A message such as `MISSING: downstream conda environment` means WSL and Miniforge are working but the shared downstream environment still needs **Install or update**. The GUI reports this as an installation status rather than an analysis failure.

## Downstream environment installation stops during package download

The installer is resumable. Run **Install or update** again. The shared Conda package cache is retained, terminal progress control codes are removed from the GUI log, and an incomplete dedicated environment prefix is repaired automatically.


## Downstream installation ends after “R packages OK”

This previously occurred when Windows PowerShell 5.1 interpreted ordinary text
written by Python or Conda to the Linux standard-error stream as a terminating
`RemoteException`. The installer now preserves both output streams in the log
and decides success only from the real WSL exit code. Run **Install or update**
again; the existing Conda environment and package cache are reused.

## The EXE appears to open slowly

A lightweight loading window now appears immediately while the full integrated
workspace is constructed. It closes automatically when the main analysis page
is ready.

## The interface is clipped or suddenly much smaller

This build leaves DPI virtualization to the Windows PowerShell host. It does
not force Per-Monitor V2 on the legacy fixed-size WinForms layout, because that
mode can enlarge child controls beyond the available work area and clip text,
buttons, and panels. Close every Bacterial RNA Analysis and PowerShell window,
then start the updated launcher so the corrected display mode takes effect.

## WSL says the supplied distribution does not exist

The suite now validates every saved WSL distribution name before using it. A stale `.wsl_distro` marker is ignored and replaced with a runnable registered Ubuntu or Debian distribution. The installer also checks the running kernel and skips `wsl --set-version` when the selected distribution is already WSL2. If no runnable distribution exists, choose **Install or repair core** and allow Windows to install Ubuntu 24.04.

### A localhost proxy warning appears before the distribution name

WSL can print a diagnostic such as `A localhost proxy configuration was
detected but not mirrored into WSL` while still launching the installed Linux
distribution successfully. The application now keeps that warning on the
standard-error channel and reads the distribution name only from clean output,
so text such as the warning plus `OpDetect-Ubuntu` cannot be passed to WSL as
one invalid `-d` argument. Close the application, start the current build, and
select **Check environment for read type** again.


## Ubuntu is installed but the installer asks to install it again
The suite now treats the WSL registry and `wsl.exe --list` as authoritative evidence that Ubuntu is installed. A short noninteractive probe is used only to rank candidates, not to decide that Ubuntu is absent. Automatic WSL1-to-WSL2 conversion runs only when Windows explicitly reports version 1. If an installed distribution still needs its first-run username/password initialization, open Ubuntu once from the Start menu and then retry setup; the suite will not offer to install a duplicate distribution.

### A distribution is reported as WSL2 and then reported missing
This indicates a stale saved or registry-only distribution name. The suite now treats `wsl.exe --list --quiet` plus a real startup marker command as authoritative, passes the validated name as a separate argument to every WSL command, and ignores registry-only names that cannot start. Extract the current build into a new folder and run **Install or repair core** again.

## WSL is listed but the suite says it has not completed a startup test
The installer now removes BOM, NUL, zero-width, direction, and other invisible Unicode control characters from WSL distribution names. It first tries the Windows default WSL distribution without passing a name. If a named distribution is listed but its quick cold-start probe is inconclusive, the installer continues with the full setup command and falls back to the default distribution before reporting an error. It will not offer to install a duplicate Ubuntu while WSL still lists an existing distribution.


## Linux setup exits with code 127

Exit code 127 means WSL started but could not locate an invoked Linux command. The Windows launcher now uses the absolute Bash path (`/bin/bash` or `/usr/bin/bash`) and verifies that the setup script is readable before starting. The Linux installer also reports the exact failing line and command. Extract the package to a local drive and rerun **Install or repair core**.

## Bash preflight incorrectly reports that Bash is absent

The Windows installer now invokes WSL with separate native arguments and the same root-user command form used by OpDetect. A lightweight Bash probe no longer blocks setup. If the probe is inconclusive, the installer continues with the full setup script and retries `/bin/bash`, `/usr/bin/bash`, and `bash` only when the shell returns exit code 126 or 127. This avoids false failures caused by PowerShell command-line reconstruction while preserving detailed diagnostics for a genuine Linux error.

## Miniforge says to run the installer with bash instead of source

The Miniforge self-extracting installer requires its own filename to end in `.sh`. Older RNA-seq setup builds downloaded it to a suffix-less temporary filename, so Miniforge incorrectly concluded that it had been sourced even though Bash was used. The current setup downloads to a verified `.sh` filename, removes only an incomplete core Miniforge prefix, retries transient downloads, and confirms that `conda` was created before continuing. Rerun **Install or repair core**; already installed Ubuntu prerequisite packages are reused.

## FADU is unavailable after featureCounts succeeds

FADU is an optional secondary bacterial-overlap audit. In the recommended combined choice, a missing Julia/FADU installation or a failed FADU audit no longer stops the run. The featureCounts integer matrix is retained for differential expression, the pipeline continues through coverage and final export, and the `FADU audit` worksheet in `RNA-seq QC and alignment.xlsx` records whether the audit completed, was skipped, or failed. Use the optional-tools installer only when the extra FADU matrix is required.
