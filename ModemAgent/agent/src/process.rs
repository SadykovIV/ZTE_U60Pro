use std::process::{Command, Output};
use std::time::Duration;

pub trait BoundedCommand {
    fn bounded_output(&mut self) -> std::io::Result<Output>;
}
impl BoundedCommand for Command {
    fn bounded_output(&mut self) -> std::io::Result<Output> {
        #[cfg(test)]
        if let Some(output) = TEST_COMMAND.with(|runner| runner.borrow_mut().as_mut().map(|run| run(self))) {
            return output;
        }
        process_runner::output(self, None, Duration::from_secs(10), 2 * 1024 * 1024)
    }
}

#[cfg(test)]
thread_local! {
    static TEST_COMMAND: std::cell::RefCell<Option<Box<dyn FnMut(&Command) -> std::io::Result<Output>>>> =
        std::cell::RefCell::new(None);
}

/// Tests intercept commands on their own thread; production has no override.
#[cfg(test)]
pub(crate) fn with_commands<R>(runner: impl FnMut(&Command) -> std::io::Result<Output> + 'static, test: impl FnOnce() -> R) -> R {
    struct Reset;
    impl Drop for Reset { fn drop(&mut self) { TEST_COMMAND.with(|r| *r.borrow_mut() = None); } }
    TEST_COMMAND.with(|r| { assert!(r.borrow().is_none()); *r.borrow_mut() = Some(Box::new(runner)); });
    let _reset = Reset;
    test()
}
