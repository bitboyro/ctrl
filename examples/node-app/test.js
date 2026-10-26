'use strict';
const assert = require('assert');
const {greeting} = require('./app');
assert.strictEqual(greeting('Ada'), 'Hello, Ada!');
assert.strictEqual(greeting('$(echo hello)'), 'Hello, $(echo hello)!');
console.log('2 greeting tests passed');
