# SnapGene and GenBank references

## Can a SnapGene design be used as an RNA-seq reference?

The sequence can be used when it represents the DNA actually present in the biological sample. A digital cloning design is not, by itself, experimental verification. Confirm the construct sequence and junctions by sequencing whenever possible.

The RNA-seq processing module currently accepts a genomic FASTA plus a matching GFF3 or GTF annotation. A SnapGene `.dna` file is not a direct pipeline input. A GenBank `.gb`, `.gbk`, or `.gbff` export is a useful source file, but it must be converted into matching FASTA and GFF3 files before selection in the interface.

## Required reference contents

For a bacterial sample, the alignment reference should normally contain:

1. The complete bacterial chromosome or chromosomes.
2. Every native plasmid present in the strain.
3. Every engineered plasmid or integrated construct present in the sample.
4. The exact construct junctions, insert orientation, deletions, substitutions, and copy of the selectable marker actually used.
5. Countable gene features with stable identifiers and correct strand and coordinate information.

Do not use only the cloned plasmid as the reference for whole-cell bacterial RNA-seq. Combine it with the matching host genome and other replicons. Each sequence must have a unique identifier.

## Suitability checks

Before analysis, verify all of the following:

* The GenBank `LOCUS` length equals the number of bases in `ORIGIN`.
* The topology is correct for each replicon, especially circular plasmids and circular bacterial chromosomes.
* The sequence contains DNA bases rather than gaps or translated protein sequence.
* Gene, CDS, rRNA, tRNA, and other intended features remain inside sequence bounds.
* Features on the reverse strand are represented as `complement(...)` in GenBank and as `-` in GFF3.
* Each countable feature has a stable `locus_tag`, `gene_id`, or `ID`.
* FASTA sequence identifiers match GFF3 column 1 exactly, including capitalization.
* No two replicons share the same identifier.
* The FASTA sequence and annotation were exported from the same final SnapGene construct version.
* The designed construct matches the physical strain used for RNA extraction.

The software performs another reference preflight during RNA-seq processing. It checks FASTA identifiers, parses the annotation, verifies coordinates, matches annotation sequence IDs to FASTA IDs, chooses a countable feature type and identifier, and reports skipped or unusable rows. Review the annotation summary and provenance log before accepting the run.

For an exact assessment, provide the GenBank export. The native SnapGene file is helpful for comparison, but the GenBank file is the primary interoperable file to inspect.
