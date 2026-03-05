use zed_extension_api::{self as zed, LanguageServerId, Result};

struct RouxExtension;

impl zed::Extension for RouxExtension {
    fn new() -> Self {
        RouxExtension
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let mix_path = worktree
            .which("mix")
            .ok_or_else(|| "mix not found in PATH".to_string())?;

        Ok(zed::Command {
            command: mix_path,
            args: vec!["roux.lsp".to_string()],
            env: Default::default(),
        })
    }
}

zed::register_extension!(RouxExtension);
