//! `Unprivileged` is the single token every privilege transition borrows or
//! consumes, so nesting is ruled out only if at most one ever exists. Law: the
//! first `take` in a process yields it and every later `take` refuses, even
//! after the first token is dropped.

use hyper_suidhelper::process::privilege::{TakeError, Unprivileged};

#[test]
fn at_most_one_token_per_process() {
    {
        let first = Unprivileged::take();
        assert!(first.is_ok(), "first take must yield the token: {first:?}");
        assert!(
            matches!(Unprivileged::take(), Err(TakeError::AlreadyTaken)),
            "second take while held"
        );
    }
    assert!(
        matches!(Unprivileged::take(), Err(TakeError::AlreadyTaken)),
        "take after the first is dropped"
    );
}
