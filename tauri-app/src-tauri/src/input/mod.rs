pub mod coordinator;
pub mod hotkey;
pub mod option_tap;
pub mod paster;

pub use coordinator::{HotkeyAction, KeyEdge, ShortcutCoordinator};
pub use hotkey::HotkeyManager;
pub use paster::Paster;
