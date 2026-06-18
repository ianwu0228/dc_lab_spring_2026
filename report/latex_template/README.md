# AAIC Project 2 Report Template

This repository is a clean LaTeX template for the AAIC Project 2 report.

## Structure

```text
.
|-- main.tex
|-- Report.sty
|-- contents/
|   |-- 01_spec_summary.tex
|   |-- 02_system_architecture.tex
|   |-- 03_design_considerations.tex
|   |-- 04_circuit_design.tex
|   `-- 05_simulation_results.tex
|-- back/
|   |-- appendix01.tex
|   `-- references.bib
|-- figs/
`-- fonts/
```

## How to Edit

1. Update the title, authors, department, and date in `main.tex`.
2. Fill each chapter under `contents/`.
3. Put schematics, waveforms, and plots in `figs/`.
4. Add references to `back/references.bib`.
5. Put detailed derivations or backup material in `back/appendix01.tex`.

## Build

Use XeLaTeX because the template supports CJK fonts.

```bash
latexmk -xelatex main.tex
```

If `latexmk` is not available, run:

```bash
xelatex main.tex
bibtex main
xelatex main.tex
xelatex main.tex
```

## Notes

- Keep all source files in UTF-8.
- Generated LaTeX files such as `.aux`, `.log`, `.out`, `.xdv`, and `.synctex.gz`
  should not be committed.
- The bundled CJK font is loaded from `fonts/Chinese/BiauKai.ttf` when available.
