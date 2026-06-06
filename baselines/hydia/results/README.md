# HyDia Similarity Results

Valid resident score-path rows used by the paper live under
`resident-real-260529/`. For a fresh rerun, write to a separate directory such
as `resident-rerun/` from the `baselines/hydia/` directory:

```bash
HYDIA_OUT_DIR=results/resident-rerun ./run_native_until_oom.sh /path/to/image_matching 12 24
./prepare_paper_outputs.py --results-dir results/resident-rerun --paper-dir /path/to/paper-tree
```
