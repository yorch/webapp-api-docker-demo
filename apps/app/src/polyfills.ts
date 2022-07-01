/**
 * Polyfill stable language features. These imports will be optimized by `@babel/preset-env`.
 *
 * See: https://github.com/zloirock/core-js#babel
 */
import 'core-js/stable';
import 'regenerator-runtime/runtime';

// TODO: Check if this is still needed
// Needed because of a bug when transpiling one of the deps of React Admin
// https://github.com/inspect-js/has-symbols/issues/6
// https://github.com/inspect-js/has-symbols/issues/4
// https://github.com/inspect-js/has-symbols/issues/11
// eslint-disable-next-line @typescript-eslint/no-explicit-any
(window as any).global = window;
