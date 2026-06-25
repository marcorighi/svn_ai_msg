# svn_ai_msg: AI‑Assisted Commit‑Message Generation for Subversion Workflows
Marco Righi  
Independent Researcher  

**Software version:** 1.0.0  
**Software DOI:** 10.5281/zenodo.20849102
**Report DOI:**   10.5281/zenodo.YYYYYYY      <!-- generated on upload -->

---

## Abstract
`svn_ai_msg` is a Bash script that automates the generation of
Subversion commit messages via a local LLM served by Ollama.
It analyses repository status and diffs, producing up to six
semantically rich message variants, thus reducing manual effort and
improving log quality.

## 1  Introduction
Traditional SVN workflows rely on hand‑written commit descriptions.
With modern LLMs, this step can be automated while retaining accuracy.
`svn_ai_msg` embeds that capability directly in Bash with no cloud
dependency.

## 2  Software description

### 2.1  Purpose & scope
* Generate multiple, semantically diverse commit messages.  
* Tunable “creativity” (temperature, top‑p, repeat penalty).  
* Supports dry‑run mode and configurable diff length.

### 2.2  Architecture
1. Calls `svn status` and `svn diff` to gather context.  
2. Builds structured prompts.  
3. Sends them to Ollama’s `/api/generate` endpoint.  
4. Post‑processes the result to match SVN conventions.

### 2.3  Dependencies
* Bash ≥ 4, SVN 1.10+  
* Python 3 (inline helpers)  
* Ollama ≥ 0.1.33 with model `qwen2.5-coder:3b`  
* Optional GPU for faster inference.

## 3  Installation
```bash
# prerequisites
sudo apt install subversion python3 git
curl -fsSL https://ollama.ai/install.sh | sh

# clone
git clone https://github.com/<username>/svn-ai-msg.git
cd svn-ai-msg
```

## 4  Usage
```bash
# default generation
./svn_ai_msg.sh

# highest creativity
./svn_ai_msg.sh -n 5

# explicit suggestion
./svn_ai_msg.sh -s "Refactor helper functions"

# dry‑run
./svn_ai_msg.sh -d
```

## 5  Results & performance
On a laptop with an i7 CPU and RTX 4060 GPU, inference takes ≈1.2 s
for 80 tokens; all five suggestions are ready in ≈3 s.

## 6  Impact and reuse potential
Automated, high‑quality commit messages enhance traceability and
auditability, especially for legacy SVN projects.

## 7  Licensing & citation
Released under the **MIT Licence**.  
Please cite the software DOI in any scholarly or production use:

```bibtex
@software{righi_2026_svnai,
  author    = {Marco Righi},
  title     = {svn_ai_msg: AI commit‑message helper for Subversion},
  version   = {1.0.0},
  year      = {2026},
  publisher = {Zenodo},
  doi       = {10.5281/zenodo.20849102},
  url       = {https://doi.org/10.5281/zenodo.20849102}
}
```

## 8  Acknowledgements
Thanks to the **Ollama** maintainers and the **Qwen** team for open
LLM models.

---

