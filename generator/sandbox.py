import os
import shutil
import stat
import subprocess

# Local isolated sandbox folder in project root
SANDBOX_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".sandbox"))


def remove_readonly(func, path, exc_info):
    """Force-deletes read-only files created by Git on Windows."""
    try:
        os.chmod(path, stat.S_IWRITE)
        func(path)
    except Exception:
        pass


def force_purge_sandbox():
    """Completely and forcefully wipes the quarantined sandbox directory."""
    if os.path.exists(SANDBOX_DIR):
        shutil.rmtree(SANDBOX_DIR, onerror=remove_readonly)


def init_sandbox() -> str:
    """Purges and recreates a clean, isolated local .sandbox directory."""
    force_purge_sandbox()
    os.makedirs(SANDBOX_DIR, exist_ok=True)
    return SANDBOX_DIR


def install_repo_dependencies(repo_target: str):
    """
    Polyglot Dependency Resolver:
    Automatically installs Python and JS/TS dependencies.
    Fails quietly if a repo uses custom/unsupported monorepo protocols.
    """
    req_file = os.path.join(repo_target, "requirements.txt")
    setup_file = os.path.join(repo_target, "setup.py")
    pyproject_file = os.path.join(repo_target, "pyproject.toml")
    pkg_json = os.path.join(repo_target, "package.json")
    pnpm_lock = os.path.join(repo_target, "pnpm-lock.yaml")

    # 1. Python Dependencies
    try:
        if os.path.exists(req_file):
            subprocess.run(["pip", "install", "-r", req_file, "--quiet"], timeout=45, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif os.path.exists(setup_file) or os.path.exists(pyproject_file):
            subprocess.run(["pip", "install", "-e", repo_target, "--quiet"], timeout=45, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

    # 2. Node.js / TypeScript / PNPM Monorepo Dependencies
    try:
        if os.path.exists(pkg_json):
            # Check if project uses pnpm workspace
            if (os.path.exists(pnpm_lock) or "workspace:" in open(pkg_json, encoding="utf-8", errors="ignore").read()) and shutil.which("pnpm"):
                subprocess.run(["pnpm", "install", "--no-frozen-lockfile"], cwd=repo_target, timeout=60, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elif shutil.which("npm"):
                subprocess.run(
                    ["npm", "install", "--legacy-peer-deps", "--no-package-lock", "--no-audit", "--no-fund"], 
                    cwd=repo_target, 
                    timeout=60, 
                    shell=True,
                    stdout=subprocess.DEVNULL, 
                    stderr=subprocess.DEVNULL
                )
    except Exception:
        pass


def clone_repo_to_sandbox(git_url: str) -> str:
    """Clones a public Git repository strictly inside .sandbox."""
    sandbox_path = init_sandbox()
    repo_target = os.path.join(sandbox_path, "repo")

    result = subprocess.run(
        ["git", "clone", "--depth", "1", git_url, repo_target],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        raise RuntimeError(f"Git clone failed: {result.stderr}")

    # AUTO-RESOLVE DEPENDENCIES
    install_repo_dependencies(repo_target)

    return repo_target


def purge_sandbox():
    """Completely wipes the quarantined sandbox directory."""
    force_purge_sandbox()