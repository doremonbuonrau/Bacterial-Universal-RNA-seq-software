# Scientific rationale and pipeline comparison

## Bacterial design

This workflow treats a bacterial genome as unspliced unless the user deliberately chooses another project outside this application. Short-read aligners therefore use bacterial settings: Bowtie2 initially uses its sensitive end-to-end behavior but exposes every official sensitivity preset, local/end-to-end mode, and expert arguments; BWA-MEM2 remains an independent alignment audit; and HISAT2 keeps splicing and soft clipping disabled while accepting expert arguments. Long reads use Minimap2 platform presets without a splice preset; Winnowmap2 is available as a repeat-placement audit. Every external processing tool also accepts optional advanced arguments through the Methods page.

PCR duplicates are not removed by default. In RNA-seq, duplicate reads may reflect genuine highly expressed molecules, so removing them can distort abundance. Secondary alignments remain in the BAM for evidence preservation, while primary gene counting and coverage explicitly exclude secondary/supplementary mappings and apply the selected MAPQ threshold.

## Adaptation of the sequencing-company workflow

The attached strand-specific prokaryotic method described rRNA depletion, a dUTP directional library, 400–500 bp library selection, PE150 sequencing, fastp, Bowtie2, HTSeq, and FPKM. The software preserves the compatible strengths and modernizes the handoff:

| Company element | Software treatment |
|---|---|
| fastp Q20 cleaning | retained, with raw and cleaned FastQC plus MultiQC |
| Bowtie2 | retained as the primary short-read accuracy choice with sensitive end-to-end as the initial setting and user-selectable presets, mode, and expert arguments |
| dUTP strand specificity | reverse-stranded default plus a per-sample forward/reverse count audit |
| HTSeq | available for reproduction, but featureCounts is the primary modern count export |
| FPKM | not used as later DE significance input; raw integer counts are exported |
| advanced analyses | intentionally excluded from execution; only required handoff files are created |

Wet-lab actions such as RNA integrity measurement, rRNA depletion, library construction, and sequencing cannot be performed or verified by this software. Their records should accompany the sample metadata.

## nf-core/rnaseq assessment

[nf-core/rnaseq](https://github.com/nf-core/rnaseq) is a strong, reproducible Nextflow pipeline and a valuable engineering reference. It is not used wholesale here because its standard choices and reporting are mainly designed around conventional reference-based, predominantly eukaryotic short-read RNA-seq. The bacterial application needs explicit unspliced alignment, prokaryotic annotation normalization, bacterial overlap auditing, direct strand handoff, long-read support, and a Windows-first guided interface.

Concepts deliberately learned from nf-core include strict sample-sheet validation, immutable inputs, technical-replicate grouping, strand cross-checking, MultiQC aggregation, resumability, software-version capture, consistent result folders, and the ability to continue from BAM evidence. nf-core/rnaseq does not become more appropriate merely by being comprehensive, and it does not use AI or neural networks for its core alignment workflow.

## AI and machine learning

AI is selected only where it has a validated direct role. [Oxford Nanopore Dorado](https://github.com/nanoporetech/dorado) uses neural models to decode POD5 electrical signal; SUP is the accuracy-first option and HAC is the lower-compute alternative. It is optional because it applies only when raw ONT signal is available.

Fastp, Bowtie2, BWA-MEM2, HISAT2, Minimap2, Winnowmap2, featureCounts, FADU, NanoPlot, LongQC, deepTools, and SAMtools are algorithmic bioinformatics tools, not AI. Adding a generic neural component to bacterial alignment would not improve accuracy without a validated task-specific model.

## Primary method references

- [Bowtie2 manual](https://bowtie-bio.sourceforge.net/bowtie2/manual.shtml)
- [Minimap2](https://github.com/lh3/minimap2)
- [Winnowmap2](https://github.com/marbl/Winnowmap)
- [fastp](https://github.com/OpenGene/fastp)
- [Cutadapt guide](https://cutadapt.readthedocs.io/en/stable/guide.html)
- [featureCounts](https://subread.sourceforge.net/featureCounts.html)
- [FADU](https://github.com/IGS/FADU)
- [NanoPlot](https://github.com/wdecoster/NanoPlot)
- [LongQC](https://github.com/yfukasawa/LongQC)
- [deepTools bamCoverage](https://deeptools.readthedocs.io/en/latest/content/tools/bamCoverage.html)
- [Dorado models](https://software-docs.nanoporetech.com/dorado/latest/models/models/)
