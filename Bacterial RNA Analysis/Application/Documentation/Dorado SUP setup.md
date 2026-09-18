# Dorado SUP setup for ONT POD5

Dorado is optional. Use it only when the input is raw Oxford Nanopore POD5. Supplied FASTQ or unaligned BAM has already been basecalled and should use **Use supplied FASTQ or unaligned BAM**.

## Does the user install Dorado?

Yes. For POD5 projects, the user must explicitly download and extract the official Dorado binary that matches the computer and accept Oxford Nanopore's license. The suite checks and uses the path you provide, but it does not silently download a platform-specific executable or choose a chemistry model. Dorado can download a compatible model automatically when given a model family such as `sup`, provided the POD5 metadata is sufficient and internet access is available.

## Why it is separate

Dorado publishes platform-specific official binaries and has hardware-dependent GPU support. It is distributed under Oxford Nanopore's license, so the core installer does not silently choose a binary or accept that license for the user.

## Installation

1. Read the [official Dorado repository and releases](https://github.com/nanoporetech/dorado).
2. Download the supported Linux build for the WSL/native Linux architecture and GPU environment.
3. Extract it to a stable location.
4. On the Methods page, set **Dorado executable** to the Linux-accessible executable path. `dorado` is sufficient if its `bin` folder is already on Linux `PATH`.
5. Set the model to `sup` only when Dorado can identify a compatible model from POD5 metadata. Otherwise enter the exact chemistry- and sampling-rate-matched model documented in the [official model table](https://software-docs.nanoporetech.com/dorado/latest/models/models/).
6. Choose **Dorado SUP neural basecalling**. SUP is the accuracy-first family; HAC is a compromise, not the maximum-accuracy choice.
7. Run the environment check before starting the project.

Never guess a direct-RNA chemistry model. A model mismatch can be more damaging than choosing HAC versus SUP within the correct chemistry.

The workflow preserves the Dorado BAM and derives FASTQ for independent bacterial reference alignment. The basecalled BAM is evidence, not a replacement for the final coordinate-sorted reference BAM.
