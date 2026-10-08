'use strict';
// Executable names and the default build directory for the current platform.
const path = require('path');
const windows = process.platform === 'win32';
const out = process.env.LAMP_OUT ? path.resolve(process.env.LAMP_OUT) : path.join(__dirname, '..', windows ? 'bin' : process.platform === 'darwin' ? 'build/macos' : 'build');
const exe = (directory, name) => path.join(directory, name + (windows ? '.exe' : ''));
module.exports = {windows, out, exe, cli: (directory = out) => exe(directory, 'lamp-cli')};
