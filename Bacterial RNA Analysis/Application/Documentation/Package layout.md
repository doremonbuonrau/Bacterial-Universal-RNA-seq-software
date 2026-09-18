# Package layout

Open **Bacterial RNA Analysis.exe** from the outer folder.

The **Application** folder contains program files and should remain beside the launcher. Routine users do not need to edit it.

Maintenance utilities are in `Application/Maintenance`:

- `Install or Repair.bat`
- `Check Environment.bat`
- `Open Linux Terminal.bat`
- `Debug Bacterial RNA Analysis.bat`
- `Uninstall Bacterial RNA Analysis.bat`

The uninstall utility can selectively remove core RNA-seq, downstream analysis, or OpDetect environments. It can also remove package-local caches or the extracted application itself. Dangerous options such as deleting an entire WSL distribution are never selected by default and require an additional confirmation.


## Guides

- `Documentation/User Guide.html` is the overall software guide opened from the first analysis-module page.
- `Documentation/RNA-seq Processing Guide.html` is the dedicated processing-module guide opened from the five-page RNA-seq workflow.
- Each downstream and operon module retains its own instructions inside its module folder.
