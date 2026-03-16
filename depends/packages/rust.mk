package=rust
$(package)_version=1.32.0
$(package)_download_path=https://static.rust-lang.org/dist
$(package)_file_name_linux=rust-$($(package)_version)-x86_64-unknown-linux-gnu.tar.gz
$(package)_sha256_hash_linux=e024698320d76b74daf0e6e71be3681a1e7923122e3ebd03673fcac3ecc23810
$(package)_file_name_darwin=rust-$($(package)_version)-x86_64-apple-darwin.tar.gz
$(package)_sha256_hash_darwin=f0dfba507192f9b5c330b5984ba71d57d434475f3d62bd44a39201e36fa76304
$(package)_file_name_mingw32=rust-mingw-$($(package)_version)-x86_64-pc-windows-gnu.tar.gz
$(package)_sha256_hash_mingw32=4f965889258a30900543074b83b49904b84d37f2b4abfe5b8a5aaa5ce081c509


define $(package)_stage_cmds
  ./install.sh --destdir=$($(package)_staging_dir) --prefix=$(host_prefix)/native --disable-ldconfig
endef
