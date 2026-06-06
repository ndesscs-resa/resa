# resident-real-260529

Directory for the HyDia resident score-path result files used by the paper.

After a resident HyDia run finishes or fails at a resident boundary, place the
result files here and run:

```bash
../../prepare_paper_outputs.py --results-dir . --paper-dir /path/to/paper-tree
```

The same command can be run from `baselines/hydia` with
`--results-dir results/resident-real-260529`.
