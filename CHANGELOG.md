# Changelog

## [0.2.1](https://github.com/nmbrone/minch/compare/v0.2.0...v0.2.1) (2025-07-04)


### Bug Fixes

* properly handle :done message ([#55](https://github.com/nmbrone/minch/issues/55)) ([a1e597a](https://github.com/nmbrone/minch/commit/a1e597a850aa9f85c141bde4444f202ed4524e19))

## [0.2.0](https://github.com/nmbrone/minch/compare/v0.1.0...v0.2.0) (2025-06-11)


### ⚠ BREAKING CHANGES

* remove `{:reconnect, state}` result from `handle_info/2` callback
* remove public `Minch.Conn`
* add connection attempt to the `handle_disconnect` callback ([#42](https://github.com/nmbrone/minch/issues/42))
* handle control frames automatically ([#40](https://github.com/nmbrone/minch/issues/40))
* replace c:handle_connect/1 with c:handle_connect2 ([#33](https://github.com/nmbrone/minch/issues/33))

### Features

* add `{:close, code, reason, state}` callback result ([#53](https://github.com/nmbrone/minch/issues/53)) ([bc11ac2](https://github.com/nmbrone/minch/commit/bc11ac2f14d9aea328e9a68e13314173fe62e303))
* add `{:stop, reason, state}` result to some callbacks ([b9430da](https://github.com/nmbrone/minch/commit/b9430dad3eeb1a6961812f47f0efcfc435cb6a89))
* add `handle_error/2` callback ([e061ab4](https://github.com/nmbrone/minch/commit/e061ab4b89cae3458e7fed1fb0c05c5eb36dc545))
* add `Minch.backoff/2` ([e061ab4](https://github.com/nmbrone/minch/commit/e061ab4b89cae3458e7fed1fb0c05c5eb36dc545))
* add connection attempt to the `handle_disconnect` callback ([#42](https://github.com/nmbrone/minch/issues/42)) ([3193661](https://github.com/nmbrone/minch/commit/3193661fa2ecfa507d0c0bfab5b8a5b061a6982d))
* default implementation for more callbacks ([e061ab4](https://github.com/nmbrone/minch/commit/e061ab4b89cae3458e7fed1fb0c05c5eb36dc545))
* handle control frames automatically ([#40](https://github.com/nmbrone/minch/issues/40)) ([c41c577](https://github.com/nmbrone/minch/commit/c41c5773076f6d2bc2489d40ca31f953f1fe0733))
* remove `{:reconnect, state}` result from `handle_info/2` callback ([e061ab4](https://github.com/nmbrone/minch/commit/e061ab4b89cae3458e7fed1fb0c05c5eb36dc545))
* remove public `Minch.Conn` ([e061ab4](https://github.com/nmbrone/minch/commit/e061ab4b89cae3458e7fed1fb0c05c5eb36dc545))
* replace c:handle_connect/1 with c:handle_connect2 ([#33](https://github.com/nmbrone/minch/issues/33)) ([4f659b5](https://github.com/nmbrone/minch/commit/4f659b5300dc563226274379cc3645f0330a2840))


### Bug Fixes

* handle case when the upgrade response is coming in different messages ([e061ab4](https://github.com/nmbrone/minch/commit/e061ab4b89cae3458e7fed1fb0c05c5eb36dc545))
* handle timeout in simple client ([#45](https://github.com/nmbrone/minch/issues/45)) ([6e67643](https://github.com/nmbrone/minch/commit/6e676432bb21025d2cab3b9fc16baaf2c5e653d0))
* **TestServer:** fix dialyzer error ([#49](https://github.com/nmbrone/minch/issues/49)) ([1ec1d0e](https://github.com/nmbrone/minch/commit/1ec1d0e02d50df166007137b8df0a92fd7e3f585))

## 0.1.0 (2023-10-12)


### Features

* initial release ([1bb8bcf](https://github.com/nmbrone/minch/commit/1bb8bcf411aa26145f8ab125986d20ef5f14f994))


### Miscellaneous Chores

* trigger the release ([be8ba9e](https://github.com/nmbrone/minch/commit/be8ba9eea7a774d4d606740a3104001d8d42bc05))
