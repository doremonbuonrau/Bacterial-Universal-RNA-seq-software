# Shared Database Library

Bacterial RNA Analysis keeps reusable biological database resources in one persistent library inside the shared WSL environment:

`/root/.local/share/prok-rnaseq/Database Library`

Use the **Database library** button in GO/Enrichment, Co-expression/Networks, STRING, Pathway Database Analysis, Transcript Discovery, or other Scientific Expansion pages to open the folder from Windows Explorer.

## Why this exists

Large reference resources should not be downloaded separately for every project. Once a valid database is retrieved, the suite stores it in this library and reuses it across projects and software versions. A resource is downloaded again only when the user explicitly selects **Update shared ... library copy**, the cached file fails integrity validation, or the user removes it.

## Library contents

- `UniProt/` contains the reviewed Swiss-Prot fallback, exact-organism reviewed + TrEMBL FASTA files, conservative genus-lineage reviewed + TrEMBL sequence-rescue libraries when an exact strain is absent, organism-specific annotation tables, metadata, and reusable DIAMOND indexes. Taxonomic sequence rescue is stored under `UniProt/Taxonomy sequence libraries/` and is reused automatically.
- `STRING/` contains reusable STRING REST responses keyed by organism and exact request parameters. Identical future requests can run from the cached response.
- `KEGG/` contains organism-specific pathway-to-gene mappings retrieved after explicit user confirmation of the applicable KEGG usage conditions.
- `Rfam/` contains user-supplied `Rfam.cm`, `Rfam.clanin`, and matching pressed database files copied from the first Transcript Discovery run. Later runs can reuse them without selecting the files again.
- `Pathway mappings/` preserves imported BioCyc, MetaCyc, and custom TERM2GENE mappings for reuse and provenance. The software does not bypass third-party licensing requirements.
- `library_manifest.json` records the location, size, version/provenance information, and update time of reusable resources.

## Genes that do not match Swiss-Prot

Swiss-Prot is manually reviewed and intentionally incomplete, so bacterial genes should not be expected to match it all. The software therefore uses a conservative rescue ladder rather than forcing a Swiss-Prot assignment:

1. Recover exact identifiers, product/function text, and explicit GO terms from the retained RNA Processing GFF/GTF and gene metadata.
2. Try exact-organism UniProtKB reviewed + TrEMBL identifiers and proteins.
3. If a recently deposited strain has no exact UniProt proteome, search the nearest genus-lineage UniProtKB reviewed + TrEMBL protein library by sequence with DIAMOND. Very large lineage libraries are not downloaded automatically.
4. Use the global reviewed Swiss-Prot database as the final high-confidence homology fallback.
5. Keep genes without defensible GO evidence explicitly unmatched rather than inventing annotations. `genes_without_go.tsv` records those genes and the reason.

The lineage step is sequence-homology only. A gene name shared between species is never sufficient by itself to transfer an annotation.

## Existing installations

When GO/Network annotation starts, the suite automatically checks the older functional-annotation cache under `~/.cache/bacterial-rna-analysis/functional-annotation`. Valid existing UniProt/Swiss-Prot downloads are migrated into the Shared Database Library so that users do not need to download them again.

## Updating a database

Normally leave update/refresh controls off. Use them only when you intentionally want a newer database release or need to replace a damaged cache. Project result folders still receive copies of the relevant small mapping/audit files needed for reproducibility; the large reusable database itself remains in the shared library.
