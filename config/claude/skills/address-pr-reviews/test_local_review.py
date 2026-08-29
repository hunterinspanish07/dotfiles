#!/usr/bin/env python3
"""Behavior tests for the local PR-review engine's verdict identity.

The engine identifies its own artifacts by stamps only it writes: a comment is
an engine verdict because it carries the verdict stamp
`<!-- pr-review:verdict model="..." sha="..." -->` — never because its prose
mentions `REVIEW_COMPLETE`, which any human can quote. These tests pin the
behaviors that depend on that: `_human_replies` must not swallow human replies
that quote the trailer, `_latest_review_comment` must be scoped to the asking
model's stamp and must halt on a stamp with no count, legacy stamps must match
nothing, and the stamp/trailer round-trip must hold.

[LAW:behavior-not-structure] every test asserts observable output — what
`_human_replies` returns, what `_latest_review_comment` finds or raises, what
`_stamp` emits — never call order or private plumbing. Fixture comments carry
the stamps LITERALLY, not via `_verdict_stamp`, so a broken stamper cannot
pass its own round-trip.

[LAW:effects-at-boundaries] the one effect in the code under test — the `gh`
API read — is stubbed at its boundary: `local_review._gh_json` is monkeypatched
to return fixture lists shaped exactly like the real `--jq` projection
(`{"author", "body", "created_at"}`). No `gh`, no network, no git.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

import pytest

import local_review

# Two distinct reviewing configurations, as a Runner's `model` names them.
MODEL_A = "xai/grok-4.6"
MODEL_B = "openrouter/z-ai/glm-5.3"

HEAD_SHA = "0123456789abcdef0123456789abcdef01234567"
BASE_SHA = "89abcdef0123456789abcdef0123456789abcdef"


def _comment(author: str, body: str, created_at: str) -> dict:
    """One PR comment in the exact shape the engine's `--jq` projection reads."""
    return {"author": author, "body": body, "created_at": created_at}


def _verdict_body(model: str, sha: str, count: int) -> str:
    """A verdict comment body as the engine posts it: findings, the verdict
    stamp, then the trailer as the last line."""
    return (
        f"Findings from {model} on {sha[:8]}.\n\n"
        f'<!-- pr-review:verdict model="{model}" sha="{sha}" -->\n\n'
        f"REVIEW_COMPLETE: {count}"
    )


def _issue_comments(monkeypatch, comments: list) -> None:
    """Point the engine's PR-comment read at a fixture: issue comments return
    `comments`; review-thread comments (the other endpoint `_human_replies`
    reads) return none. Mirrors the real `_gh_json` seam — same arguments, same
    list-of-dicts shape — so the code under test runs unmodified."""

    def stub(*args: str):
        assert args[0] == "api", f"unexpected gh call: {args}"
        return comments if "/issues/" in args[1] else []

    monkeypatch.setattr(local_review, "_gh_json", stub)


# --- _human_replies: what the reviewer's prompt carries -----------------------


def test_human_reply_quoting_the_trailer_is_returned(monkeypatch):
    # Bug 2, hit live on PR #144: a human comment quoting `REVIEW_COMPLETE: 0`
    # is a reply the reviewer must see. Keying the drop on that prose silently
    # swallowed it; the drop must key on the engine's stamp instead.
    _issue_comments(monkeypatch, [
        _comment(
            "alice",
            "I think we're done here — the last pass ended REVIEW_COMPLETE: 0, "
            "so please double-check the remaining edge case before merge.",
            "2026-08-29T10:00:00Z",
        ),
    ])
    replies = local_review._human_replies("owner", "repo", 144, "")
    assert "@alice:" in replies
    assert "remaining edge case" in replies


def test_stamped_verdict_comment_is_not_returned(monkeypatch):
    _issue_comments(monkeypatch, [
        _comment("github-actions[bot]", _verdict_body(MODEL_A, HEAD_SHA, 2),
                 "2026-08-29T10:00:00Z"),
    ])
    assert local_review._human_replies("owner", "repo", 1, "") == ""


def test_marker_comment_is_not_returned(monkeypatch):
    _issue_comments(monkeypatch, [
        _comment("github-actions[bot]",
                 "🔍 **Grok reviewer triggered** — verdict to follow.\n\n"
                 "<!-- pr-review:marker -->",
                 "2026-08-29T10:00:00Z"),
    ])
    assert local_review._human_replies("owner", "repo", 1, "") == ""


# --- _latest_review_comment: whose verdict this is ----------------------------


def test_other_models_verdict_is_not_this_models_verdict(monkeypatch):
    # Bug 1: a verdict from a different model must never stand in for this
    # model's — otherwise the cheap reviewer's pass blocks the strong one from
    # ever running, and the operator believes the strong model verified.
    _issue_comments(monkeypatch, [
        _comment("github-actions[bot]", _verdict_body(MODEL_B, HEAD_SHA, 0),
                 "2026-08-29T10:00:00Z"),
    ])
    assert local_review._latest_review_comment("owner", "repo", 1, MODEL_A) is None


def test_each_model_reads_back_its_own_newest_verdict(monkeypatch):
    # Model B's newer verdict must not shadow model A's own verdict when A is
    # the reviewer being run.
    _issue_comments(monkeypatch, [
        _comment("github-actions[bot]", _verdict_body(MODEL_A, BASE_SHA, 3),
                 "2026-08-28T10:00:00Z"),
        _comment("github-actions[bot]", _verdict_body(MODEL_B, HEAD_SHA, 1),
                 "2026-08-29T10:00:00Z"),
    ])
    n, comment = local_review._latest_review_comment("owner", "repo", 1, MODEL_A)
    assert n == 3
    assert comment["body"] == _verdict_body(MODEL_A, BASE_SHA, 3)


def test_legacy_stamp_is_a_verdict_for_no_model(monkeypatch):
    # The retired stamp format matches nothing: cold baseline, full PR
    # re-reviewed once — err toward running a review, never toward skipping.
    _issue_comments(monkeypatch, [
        _comment(
            "github-actions[bot]",
            f"Old-format verdict.\n\n"
            f"<!-- pr-review:reviewed-sha: {HEAD_SHA} -->\n\n"
            f"REVIEW_COMPLETE: 1",
            "2026-08-29T10:00:00Z",
        ),
    ])
    for model in (MODEL_A, MODEL_B):
        assert local_review._latest_review_comment("owner", "repo", 1, model) is None


def test_stamped_verdict_without_trailer_halts(monkeypatch):
    # A verdict stamp with no count is a broken engine artifact — halt loudly,
    # never read it as zero and never skip past it.
    _issue_comments(monkeypatch, [
        _comment(
            "github-actions[bot]",
            f"Findings, but the count never landed.\n\n"
            f'<!-- pr-review:verdict model="{MODEL_A}" sha="{HEAD_SHA}" -->',
            "2026-08-29T10:00:00Z",
        ),
    ])
    with pytest.raises(RuntimeError, match="REVIEW_COMPLETE"):
        local_review._latest_review_comment("owner", "repo", 1, MODEL_A)


# --- the stamp itself ---------------------------------------------------------


def test_stamp_keeps_the_trailer_last_and_carries_the_verdict_stamp():
    stamped = local_review._stamp(
        "Finding 1: the seam is rough.\n\nREVIEW_COMPLETE: 1", MODEL_A, HEAD_SHA
    )
    assert stamped.splitlines()[-1] == "REVIEW_COMPLETE: 1"
    m = local_review.VERDICT_RE.search(stamped)
    assert m, "the verdict stamp must be findable in the stamped review"
    assert m.group(1) == MODEL_A
    assert m.group(2) == HEAD_SHA


def test_stamp_lands_on_the_real_trailer_not_a_quoted_count():
    # A review that quotes an earlier pass's count in prose before delivering
    # the real trailer: the stamp must sit directly above the REAL trailer —
    # the last match, the contract's final line — not beside the quote.
    review = (
        "The previous pass reported REVIEW_COMPLETE: 2; both concerns are now "
        "fixed in this push.\n\nREVIEW_COMPLETE: 0"
    )
    stamped = local_review._stamp(review, MODEL_A, HEAD_SHA)
    lines = stamped.splitlines()
    assert lines[-1] == "REVIEW_COMPLETE: 0"
    assert lines[-3] == local_review._verdict_stamp(MODEL_A, HEAD_SHA)


def test_count_read_back_is_the_trailers_not_a_quoted_count(monkeypatch):
    # The verdict the engine posts from a review that quoted an earlier count:
    # the count read back must be the trailer's, never the quoted one.
    _issue_comments(monkeypatch, [
        _comment("github-actions[bot]",
                 local_review._stamp(
                     "Previous pass said REVIEW_COMPLETE: 2 — both fixed.\n\n"
                     "REVIEW_COMPLETE: 0",
                     MODEL_A, HEAD_SHA),
                 "2026-08-29T10:00:00Z"),
    ])
    n, _ = local_review._latest_review_comment("owner", "repo", 1, MODEL_A)
    assert n == 0


def test_verdict_stamp_round_trips():
    m = local_review.VERDICT_RE.search(local_review._verdict_stamp(MODEL_B, HEAD_SHA))
    assert m
    assert (m.group(1), m.group(2)) == (MODEL_B, HEAD_SHA)


# --- _baseline: what the standing verdict carries into the prompt -------------


def test_standing_verdict_carries_findings_but_not_the_engine_stamp(monkeypatch):
    """`Baseline.standing` is quoted back to the model verbatim, so it must
    carry the previous findings and NOT the engine's stamp. A stamp the model
    can see is a stamp it can echo, and an echoed stamp would sit ahead of the
    real one in the next posted verdict — an older answer to "which commit did
    this judge" that `VERDICT_RE.search` would reach first."""
    _issue_comments(monkeypatch, [
        _comment("bot", _verdict_body(MODEL_A, BASE_SHA, 2), "2026-08-29T10:00:00Z"),
    ])
    monkeypatch.setattr(local_review, "_have", lambda root, rev: True)
    monkeypatch.setattr(local_review, "_resolve", lambda root, rev: rev)

    baseline = local_review._baseline("owner", "repo", 1, "/tmp", HEAD_SHA, MODEL_A)

    assert baseline.sha == BASE_SHA
    assert local_review.VERDICT_RE.search(baseline.standing) is None
    assert "pr-review:verdict" not in baseline.standing
    # The findings — and the model's own trailer, which `_trailer` resolves by
    # last match — must survive; only the engine's bookkeeping is removed.
    assert "Findings from" in baseline.standing
    assert "REVIEW_COMPLETE: 2" in baseline.standing


def test_an_older_malformed_verdict_does_not_wedge_the_current_one(monkeypatch):
    """A stamped comment with no trailer that is NOT the newest must be passed
    over, not raised on. Raising mid-scan wedges every future read of the PR
    for that model — a stale comment (a human pasting a stamp while discussing
    the mechanism) would permanently block a perfectly good newer verdict, with
    no recovery except editing PR history."""
    _issue_comments(monkeypatch, [
        _comment("someone", f'<!-- pr-review:verdict model="{MODEL_A}" sha="{BASE_SHA}" -->',
                 "2026-08-29T09:00:00Z"),
        _comment("bot", _verdict_body(MODEL_A, HEAD_SHA, 0), "2026-08-29T10:00:00Z"),
    ])
    n, comment = local_review._latest_review_comment("owner", "repo", 1, MODEL_A)
    assert n == 0
    assert HEAD_SHA in comment["body"]


def test_the_newest_verdict_missing_its_trailer_still_halts(monkeypatch):
    """The check moved to the selected verdict, but it must still fire there:
    the CURRENT verdict with no count is a missing count, never a clean zero."""
    _issue_comments(monkeypatch, [
        _comment("bot", _verdict_body(MODEL_A, BASE_SHA, 0), "2026-08-29T09:00:00Z"),
        _comment("someone", f'<!-- pr-review:verdict model="{MODEL_A}" sha="{HEAD_SHA}" -->',
                 "2026-08-29T10:00:00Z"),
    ])
    with pytest.raises(RuntimeError, match="count is missing"):
        local_review._latest_review_comment("owner", "repo", 1, MODEL_A)
