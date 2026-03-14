// Rail Language Extension for VS Code
// Provides syntax highlighting and LSP client connection

const vscode = require('vscode');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;

function activate(context) {
    // Find the rail binary
    const railPath = vscode.workspace.getConfiguration('rail').get('path', 'rail');

    const serverOptions = {
        command: railPath,
        args: ['lsp'],
        transport: TransportKind.stdio
    };

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
}

function deactivate() {
    if (client) {
        return client.stop();
    }
}

module.exports = { activate, deactivate };
