---
title: "Footnote / Citation Interleaving Test"
bibliography: refs.json
---

# Footnote and citation interleaving test

## Beginning

This opening paragraph carries my own hand-written aside right away[^alpha].
It exists to claim the first footnote slot before any citation appears, so we
can see whether citeproc inserts generated notes ahead of it or after it.

## Middle: a lone citation

Here a Pandoc citation stands by itself with no hand-written marker nearby
[@key1]. Under a notes style this should generate a footnote; under
author-date it should stay inline. Nothing of mine competes for this slot.

## Same-sentence edge case

This is a claim with my own aside[^beta] and also a citation [@key2], placed
immediately adjacent so we can see which note number lands first when a
hand-written marker and a citation share one sentence.

## Reference-before-definition edge case

This sentence references a footnote[^gamma] whose definition is written far
below, after the citation[@key1] that follows it here, to test whether
numbering follows *reference* order or *definition* order in the source.

## End

A final hand-written footnote closes the document[^delta] to confirm the last
slot in the merged sequence.

[^beta]: Beta note — defined in the middle of the source, near its reference.

[^alpha]: Alpha note — note that this definition is written out of order,
after beta's, even though alpha is referenced first.

[^gamma]: Gamma note — its reference appeared before this definition and
before a citation; defined here, late.

[^delta]: Delta note — the last hand-written note.
