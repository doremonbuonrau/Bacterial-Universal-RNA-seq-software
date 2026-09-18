# Guided command-line tool options

The **Guided tool options...** dialog exposes documented, validated controls for the processing tools used by Bacterial RNA Analysis. The user chooses a tool on the left and can enable supported options with checkboxes, drop-downs, and validated fields.

## Offline manuals

Every tool page has **Open offline manual**. The manual is bundled inside `Documentation/Offline manuals/RNA-seq processing` and opens without Internet access. It records the tool's role, pipeline-managed arguments, every option exposed by this application, defaults, accepted choices, and the official upstream documentation source.

## Bowtie2

Bowtie2 preset and alignment mode are configured directly inside the **Bowtie2 alignment** page, together with its other options. They are no longer separate controls above the tool list.

The application defaults remain **sensitive** and **end-to-end**. Available presets are `default`, `very-fast`, `fast`, `sensitive`, and `very-sensitive`. Available modes are `end-to-end` and `local`.

## Reproducibility and safety

Free-form custom command arguments are intentionally not exposed. Only options listed in the guided table can change a command. Input files, output paths, threads, read groups, pipes, required counting settings, and other workflow-owned values remain protected.

Every effective command is still written to the run log so the complete executed command line can be audited after the run.
