# Third-party tools and installation policy

The suite does not redistribute the bioinformatics binaries. The core installer resolves open-source packages from conda-forge and Bioconda into an isolated environment. Optional source tools are installed only when the user selects their installer.

| Tool family | Role | Installation |
|---|---|---|
| FastQC, fastp, Cutadapt, MultiQC | short-read QC/cleaning/reporting | core Conda environment |
| Bowtie2, BWA-MEM2, HISAT2 | selectable short-read bacterial alignment | core Conda environment |
| SAMtools | BAM sort, merge, index, validation, statistics | core Conda environment |
| Minimap2, Winnowmap2, meryl | long-read mapping and repeat audit | core Conda environment |
| NanoPlot, Chopper | long-read QC and optional filtering | core Conda environment |
| featureCounts/Subread, HTSeq | raw count preparation and strand audit | core Conda environment |
| deepTools bamCoverage | BigWig/bedGraph coverage | core Conda environment |
| FADU + Julia | optional prokaryotic overlap audit | explicit optional installer from [IGS/FADU](https://github.com/IGS/FADU) |
| LongQC | optional reference-free long-read diagnostic | explicit optional installer from [yfukasawa/LongQC](https://github.com/yfukasawa/LongQC) |
| Dorado | optional ONT neural basecalling | user-selected official build from [nanoporetech/dorado](https://github.com/nanoporetech/dorado) |

Each project exports resolved executable paths, version text, executable SHA-256, and one bounded record per installed Conda package. The package record includes version, build, channel, license, dependencies, binary/upstream URLs, package hash, and SHA-256 of the complete original Conda metadata record when available. Conda `files` and `paths_data.paths` arrays are not printed because they are installation file inventories rather than source code or generated analysis code; excluding them prevents hundreds of thousands of irrelevant log lines without weakening package identity. Consult the upstream project for the citation, supported platforms, and current release notes before publication or regulated use.

The RNA-seq processing Methods page also provides **Guided tool options**. Every external command has its own page with a summary, workflow-owned inputs, common **Use** checkboxes, drop-downs, validated values, a bundled offline manual, and an effective-argument preview. Bowtie2 preset and alignment mode are configured inside the Bowtie2 alignment page. Free-form custom flags are intentionally not exposed. The active structured configuration and exact effective commands are preserved in the project provenance logs.


## Downstream analysis environment

The integrated downstream GUI uses a separate conda environment named `prok-rnaseq-downstream`. It is created only when the user selects **Install or update** in the downstream status panel.

| Tool family | Role | Installation |
|---|---|---|
| edgeR, DESeq2, limma-voom | replicated count-based differential expression | downstream Conda environment |
| clusterProfiler | custom over-representation analysis and result framework | downstream Conda environment |
| fgsea | ranked gene-set enrichment | downstream Conda environment |
| topGO | GO topology-aware enrichment | downstream Conda environment |
| CEMiTool | automated co-expression modules | downstream Conda environment |
| WGCNA | advanced weighted co-expression modules and module-trait analysis | downstream Conda environment |
| GENIE3 | directed regulator-target prediction | downstream Conda environment |
| pandas, NumPy, Plotly, NetworkX | table handling and local interactive visualization | downstream Conda environment |
| CairoSVG, Pillow | PDF, PNG, JPEG, and TIFF publication export from browser-generated SVG | downstream Conda environment |

The suite does not bundle remote pathway databases. For non-model bacteria, users supply a compatible gene-to-term table or GMT file and retain responsibility for its source, version, identifier mapping, and licensing.
