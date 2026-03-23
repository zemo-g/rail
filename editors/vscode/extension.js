// Rail Language Extension for VS Code
// Provides syntax highlighting and LSP client connection

const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;

function activate(context) {
    const config = vscode.workspace.getConfiguration('rail');

    // Try to find the LSP server. Priority:
    // 1. Explicit rail.lspPath setting
    // 2. Python LSP server relative to extension (tools/lsp_server.py)
    // 3. Fall back to `rail lsp` command
    let serverOptions;

    const explicitLspPath = config.get('lspPath', '');
    if (explicitLspPath && fs.existsSync(explicitLspPath)) {
        // Explicit path to LSP server script
        serverOptions = {
            command: 'python3',
            args: [explicitLspPath],
            transport: TransportKind.stdio
        };
    } else {
        // Try to find lsp_server.py relative to the workspace or extension
        const workspaceFolders = vscode.workspace.workspaceFolders;
        let lspScript = null;

        // Check workspace root (for when editing rail itself)
        if (workspaceFolders) {
            for (const folder of workspaceFolders) {
                const candidate = path.join(folder.uri.fsPath, 'tools', 'lsp_server.py');
                if (fs.existsSync(candidate)) {
                    lspScript = candidate;
                    break;
                }
            }
        }

        // Check relative to extension install path
        if (!lspScript) {
            const extRelative = path.join(context.extensionPath, '..', '..', 'tools', 'lsp_server.py');
            if (fs.existsSync(extRelative)) {
                lspScript = extRelative;
            }
        }

        if (lspScript) {
            serverOptions = {
                command: 'python3',
                args: [lspScript],
                transport: TransportKind.stdio
            };
        } else {
            // Fall back to rail binary with lsp subcommand
            const railPath = config.get('path', 'rail');
            serverOptions = {
                command: railPath,
                args: ['lsp'],
                transport: TransportKind.stdio
            };
        }
    }

    const clientOptions = {
        documentSelector: [{ scheme: 'file', language: 'rail' }],
    };

    client = new LanguageClient(
        'rail-lsp',
        'Rail Language Server',
        serverOptions,
        clientOptions
    );

    client.start();

    // Show which server is being used
    const cmd = serverOptions.command;
    const args = serverOptions.args.join(' ');
    vscode.window.setStatusBarMessage(`Rail LSP: ${cmd} ${args}`, 5000);
}

function deactivate() {
    if (client) {
        return client.stop();
    }
}

module.exports = { activate, deactivate };
