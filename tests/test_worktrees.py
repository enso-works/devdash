import os
import subprocess
import time

import pytest

from devdash import worktrees


def git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True)


@pytest.fixture
def repo(tmp_path):
    """main, plus worktrees that are merged, have changes, have unmerged commits, and run something."""
    root = tmp_path / "app"
    root.mkdir()
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.email", "t@example.com")
    git(root, "config", "user.name", "t")
    (root / "README").write_text("hi\n")
    git(root, "add", ".")
    git(root, "commit", "-qm", "init")
    for name in ("merged", "changes", "ahead", "busy"):
        git(root, "worktree", "add", "-q", "-b", name, str(tmp_path / name))
    (tmp_path / "changes" / "new.txt").write_text("x\n")
    (tmp_path / "ahead" / "file").write_text("x\n")
    git(tmp_path / "ahead", "add", ".")
    git(tmp_path / "ahead", "commit", "-qm", "work")
    return os.path.realpath(tmp_path)


def by_branch(repo_dir):
    found = worktrees.scan({f"{repo_dir}/app"})
    assert len(found) == 1
    return {w.branch: w for w in found[0].worktrees}


def test_parse_porcelain():
    text = (
        "worktree /r\nHEAD 1234567890abcdef\nbranch refs/heads/main\n\n"
        "worktree /r/.claude/worktrees/a\nHEAD abcdef1234567890\ndetached\nlocked\n\n"
        "worktree /gone\nHEAD 1111111111111111\nbranch refs/heads/x\nprunable gitdir file points to non-existent location\n"
    )
    main, agent, gone = worktrees.parse_porcelain(text)
    assert main.is_main and main.branch == "main" and main.head == "1234567"
    assert not agent.is_main and agent.branch == "" and agent.locked
    assert gone.prunable and gone.branch == "x"
    assert worktrees.created_by(agent.path) == "claude"


def test_status_priority():
    now = time.time()
    old = now - 30 * 86400
    assert worktrees.status(worktrees.Worktree("p", "b", "h", prunable=True, changes=2), now) == "missing"
    assert worktrees.status(worktrees.Worktree("p", "b", "h", changes=2, merged=True), now) == "changes"
    assert worktrees.status(worktrees.Worktree("p", "b", "h", merged=True, last_touched=old), now) == "merged"
    assert worktrees.status(worktrees.Worktree("p", "b", "h", last_touched=old, last_commit=old), now) == "stale"
    assert worktrees.status(worktrees.Worktree("p", "b", "h", last_touched=now), now) == "active"


def test_scan(repo):
    wts = by_branch(repo)
    assert wts["main"].is_main
    assert wts["merged"].merged and wts["merged"].status == "merged"
    assert wts["changes"].changes == 1 and wts["changes"].status == "changes"
    assert not wts["ahead"].merged and wts["ahead"].status == "active"
    assert wts["ahead"].subject == "work"


def test_scan_skips_repos_without_worktrees(tmp_path):
    git(tmp_path, "init", "-q")
    assert worktrees.scan({str(tmp_path)}) == []


def test_remove_refuses_main_changes_and_busy(repo):
    with pytest.raises(ValueError, match="main checkout"):
        worktrees.remove(f"{repo}/app", False, [])
    with pytest.raises(ValueError, match="uncommitted"):
        worktrees.remove(f"{repo}/changes", False, [])
    with pytest.raises(ValueError, match="running"):
        worktrees.remove(f"{repo}/busy", False, [f"{repo}/busy/src"])
    assert os.path.isdir(f"{repo}/changes") and os.path.isdir(f"{repo}/busy")


def test_remove_merged_deletes_branch(repo):
    result = worktrees.remove(f"{repo}/merged", True, [f"{repo}/busy"])
    assert result["branch_deleted"] and not os.path.exists(f"{repo}/merged")
    assert "merged" not in by_branch(repo)


def test_remove_keeps_unmerged_branch(repo):
    result = worktrees.remove(f"{repo}/ahead", True, [])
    assert not result["branch_deleted"] and "not fully merged" in result["note"]
    assert not os.path.exists(f"{repo}/ahead")
    subprocess.run(["git", "-C", f"{repo}/app", "rev-parse", "--verify", "ahead"], check=True, capture_output=True)
