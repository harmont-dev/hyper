//! `Unprivileged` is the single token every privilege transition borrows or
//! consumes, so nesting is ruled out only if at most one ever exists. Law: the
//! first `take` in a process yields it and every later `take` refuses, even
//! after the first token is dropped.

use hyper_suidhelper::process::privilege::Unprivileged;

#[test]
fn at_most_one_token_per_process() {
    {
        let first = Unprivileged::take();
        assert!(first.is_some(), "first take must yield the token");
        assert!(Unprivileged::take().is_none(), "second take while held");
    }
    assert!(
        Unprivileged::take().is_none(),
        "take after the first is dropped"
    );
}
