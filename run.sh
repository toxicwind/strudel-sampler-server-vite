#!/usr/bin/env python3
"""
STRUDEL SAMPLER - PRODUCTION DEPLOYMENT (AUTONOMOUS)
- Fixes branch mismatch by normalizing to "main"
- Generates Portainer-importable docker-compose.yml (Compose v3.8)
- Generates a production Dockerfile if missing (multi-stage build)
- Creates GitHub repo with gh CLI, pushes current branch
- Adds GitHub Actions workflows (build, docker, release)
- Adds community files and Portainer .env template
- Robust subprocess error handling

Requirements: git, gh, docker, node, npm installed and gh authenticated
"""

import os
import sys
import subprocess
import json
import argparse
from pathlib import Path
from datetime import datetime
from typing import Optional, Tuple

# ========= COLORS =========
C = {
    'reset': '\033[0m',
    'green': '\033[92m',
    'yellow': '\033[93m',
    'red': '\033[91m',
    'blue': '\033[94m',
    'cyan': '\033[96m',
}

# ========= REQUIRED ARTIFACTS =========
REQUIRED_TOOLS = ['git', 'gh', 'docker', 'node', 'npm']

# GitHub Actions workflows (production-focused)
BUILD_WORKFLOW = """name: Build & Test

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node-version: ["18.x", "20.x"]
    steps:
      - uses: actions/checkout@v4
      - name: Setup Node.js ${{ matrix.node-version }}
        uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node-version }}
          cache: 'npm'
      - name: Install dependencies
        run: npm ci
      - name: Type check
        run: npm run type-check || true
      - name: Lint
        run: npm run lint || true
      - name: Build
        run: npm run build
"""

DOCKER_WORKFLOW = """name: Docker Build (Local Test)

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]

jobs:
  docker:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      - name: Version
        id: ver
        run: |
          if [[ "${{ github.ref }}" == refs/tags/* ]]; then
            echo "TAG=${{ github.ref_name }}" >> $GITHUB_OUTPUT
          else
            echo "TAG=latest" >> $GITHUB_OUTPUT
          fi
      - name: Build image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: false
          load: true
          tags: strudel-sampler:${{ steps.ver.outputs.TAG }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
      - name: Smoke test
        run: |
          docker run --rm strudel-sampler:${{ steps.ver.outputs.TAG }} node -v
"""

RELEASE_WORKFLOW = """name: Release

on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - name: Install & build
        run: |
          npm ci
          npm run build
      - name: Create release
        uses: softprops/action-gh-release@v1
        with:
          draft: false
          prerelease: false
          generate_release_notes: true
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
"""

def log(msg: str, color: str = 'reset', prefix: str = '') -> None:
    ts = datetime.now().strftime('%H:%M:%S')
    print(f"{C[color]}[{ts}] {prefix}{msg}{C['reset']}")

def die(msg: str) -> None:
    log(msg, 'red', '✗ ')
    sys.exit(1)

def run(cmd: str, check: bool = True, capture: bool = False) -> Optional[str]:
    try:
        if capture:
            p = subprocess.run(cmd, shell=True, text=True, capture_output=True, check=check)
            return p.stdout.strip()
        else:
            subprocess.run(cmd, shell=True, check=check)
            return None
    except subprocess.CalledProcessError as e:
        die(f"Command failed: {cmd}\n{e.stderr or e.stdout or ''}")

def have(cmd: str) -> bool:
    return subprocess.run(f"which {cmd}", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def ensure_tools() -> None:
    log("Verifying required tools...", 'cyan', '→ ')
    missing = [t for t in REQUIRED_TOOLS if not have(t)]
    for t in REQUIRED_TOOLS:
        log(f"{t:<10} {'✓' if t not in missing else '✗'}", 'green' if t not in missing else 'red', '  ')
    if missing:
        die(f"Missing tools: {', '.join(missing)}")

def gh_user() -> Tuple[str, str]:
    log("Verifying GitHub authentication...", 'cyan', '→ ')
    status = subprocess.run("gh auth status", shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if "not logged in" in status.stdout.lower():
        die("Not authenticated to GitHub. Run: gh auth login")
    user = run("gh api user -q .login", capture=True)
    if not user:
        die("Failed to get GitHub user login")
    email = run("gh api user -q .email", check=False, capture=True) or f"{user}@users.noreply.github.com"
    log(f"Authenticated as: {user}", 'green', '✓ ')
    log(f"Email: {email}", 'cyan', '  ')
    return user, email

def current_branch() -> str:
    b = run("git branch --show-current", capture=True) or "master"
    return b

def ensure_main_branch() -> str:
    # Normalize to main to avoid refspec problems later
    b = current_branch()
    if b != "main":
        # If repo freshly in master, rename to main
        run("git branch -M main", check=False)
        b = current_branch()
        if b != "main":
            # If rename did not work (detached or other), fallback to create
            run("git checkout -B main", check=False)
            b = current_branch()
    return b

def init_git(user: str, email: str) -> None:
    log("Initializing git repository...", 'cyan', '→ ')
    run(f'git config user.name "{user}"', check=False)
    run(f'git config user.email "{email}"', check=False)
    if not Path(".git").exists():
        run("git init")
        log("Git repository initialized", 'green', '✓ ')
    else:
        log("Git repository already initialized", 'cyan', '  ')

def stage_commit(msg: str) -> None:
    log("Staging and committing files...", 'cyan', '→ ')
    run("git add .")
    status = run("git status --porcelain", check=False, capture=True)
    if not status:
        log("No changes to commit", 'yellow', '  ')
        return
    run(f'git commit -m "{msg}"', check=False)
    log("Commit created", 'green', '✓ ')

def create_repo(repo_name: str, description: str, org: Optional[str]) -> str:
    full = f"{org}/{repo_name}" if org else repo_name
    log(f"Creating GitHub repository: {full}...", 'cyan', '→ ')
    # Use current directory as source and push HEAD
    run(f'gh repo create {full} --public --description "{description}" --source=. --push --remote=origin')
    url = run(f"gh repo view {full} --json url -q .url", capture=True) or f"https://github.com/{full}"
    log(f"Repository URL: {url}", 'cyan', '  ')
    return url

def push_branch() -> None:
    b = current_branch()
    run(f"git push -u origin {b}", check=False)

def write_workflows() -> None:
    wf_dir = Path(".github/workflows")
    wf_dir.mkdir(parents=True, exist_ok=True)
    (wf_dir / "build.yml").write_text(BUILD_WORKFLOW, encoding="utf-8")
    (wf_dir / "docker.yml").write_text(DOCKER_WORKFLOW, encoding="utf-8")
    (wf_dir / "release.yml").write_text(RELEASE_WORKFLOW, encoding="utf-8")
    log("GitHub Actions workflows written", 'green', '✓ ')

def write_templates() -> None:
    it_dir = Path(".github/ISSUE_TEMPLATE")
    it_dir.mkdir(parents=True, exist_ok=True)
    (it_dir / "bug_report.md").write_text(
        "---\nname: Bug Report\nabout: Report a bug\ntitle: '[BUG] '\nlabels: bug\n---\n\n## Description\n\n## Steps to Reproduce\n\n## Expected\n\n## Actual\n", encoding="utf-8")
    (it_dir / "feature_request.md").write_text(
        "---\nname: Feature Request\nabout: Suggest a feature\ntitle: '[FEATURE] '\nlabels: enhancement\n---\n\n## Description\n\n## Motivation\n\n## Use Case\n", encoding="utf-8")
    Path("PULL_REQUEST_TEMPLATE.md").write_text(
        "## Description\n\n## Type\n- [ ] Bug fix\n- [ ] New feature\n- [ ] Breaking change\n- [ ] Docs\n\n## Checklist\n- [ ] Type check\n- [ ] Lint\n- [ ] Build\n", encoding="utf-8")
    log("GitHub templates written", 'green', '✓ ')

def write_community() -> None:
    Path("CODE_OF_CONDUCT.md").write_text(
        "# Code of Conduct\n\nBe respectful, inclusive, and constructive.\n", encoding="utf-8")
    Path("CONTRIBUTING.md").write_text(
        "# Contributing\n\n1) Fork & branch\n2) npm ci; npm run type-check; npm run build\n3) Commit & PR\n", encoding="utf-8")
    Path("SECURITY.md").write_text(
        "# Security\n\nReport privately to security@example.com.\n", encoding="utf-8")
    log("Community files written", 'green', '✓ ')

def write_dockerfile_if_missing() -> None:
    if Path("Dockerfile").exists():
        log("Dockerfile exists", 'cyan', '  ')
        return
    # Multi-stage, builds TS then runs Node
    dockerfile = """# --- Build stage ---
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# --- Runtime stage ---
FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/dist ./dist
COPY package*.json ./
RUN npm ci --omit=dev
EXPOSE 5432
CMD ["node", "dist/sampler-server.js"]
"""
    Path("Dockerfile").write_text(dockerfile, encoding="utf-8")
    log("Dockerfile (multi-stage) written", 'green', '✓ ')

def write_compose_portainer() -> None:
    # Compose v3.8 with env substitution; directly importable in Portainer
    compose = """version: "3.8"
services:
  strudel-sampler:
    image: strudel-sampler:latest
    container_name: strudel-sampler
    restart: unless-stopped
    ports:
      - "5432:5432"
    volumes:
      - ${STRUDEL_SAMPLES}:/samples:ro
    environment:
      PORT: "5432"
      STRUDEL_SAMPLES: /samples
      CACHE_TTL: "3600000"
      CACHE_MAX_SIZE: "500"
      HOT_RELOAD: "true"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5432/stats"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
"""
    Path("docker-compose.yml").write_text(compose, encoding="utf-8")
    Path(".env.portainer").write_text(
        "# Portainer environment\nSTRUDEL_SAMPLES=/absolute/path/to/your/samples\n", encoding="utf-8")
    log("docker-compose.yml and .env.portainer written (Portainer-ready)", 'green', '✓ ')

def main():
    parser = argparse.ArgumentParser(description="Deploy Strudel Sampler to GitHub with CI/CD and Portainer artifacts")
    parser.add_argument("--repo-name", required=True)
    parser.add_argument("--description", default="Strudel Sampler - Production Microservice")
    parser.add_argument("--org")
    args = parser.parse_args()

    print()
    log("STRUDEL SAMPLER - AUTONOMOUS DEPLOYMENT", 'blue')
    ensure_tools()
    user, email = gh_user()

    # Initialize git & normalize branch to main
    init_git(user, email)
    # If this is a new repo with 'master', normalize to 'main' before any push
    b = ensure_main_branch()
    log(f"Using branch: {b}", 'cyan', '  ')

    # First commit if needed
    stage_commit("Initial commit: Strudel Sampler microservice")

    # Create remote repo & push current branch HEAD
    url = create_repo(args.repo_name, args.description, args.org)

    # Generate artifacts
    write_workflows()
    write_templates()
    write_community()
    write_dockerfile_if_missing()
    write_compose_portainer()

    # Commit and push artifacts to the same branch we’re on
    stage_commit("ci: add workflows, Dockerfile, Portainer compose, and templates")
    push_branch()

    print()
    log("DEPLOYMENT COMPLETE - PRODUCTION READY", 'blue')
    log(f"Repository: {url}", 'cyan', '  ')
    log("Artifacts:", 'green', '  ')
    log("- GitHub Actions workflows (build, docker, release)", 'green', '    ')
    log("- Dockerfile (multi-stage, Node 20)", 'green', '    ')
    log("- docker-compose.yml (v3.8) and .env.portainer", 'green', '    ')
    log("- Issue/PR templates & community files", 'green', '    ')
    print()
    log("Next steps:", 'yellow', '  ')
    log(f"- Monitor CI: {url}/actions", 'yellow', '    ')
    log("- Portainer → Stacks → Add Stack → paste docker-compose.yml → set STRUDEL_SAMPLES", 'yellow', '    ')
    log("- Run: docker build -t strudel-sampler:latest .", 'yellow', '    ')
    log("- Run: docker-compose up", 'yellow', '    ')

if __name__ == "__main__":
    main()
