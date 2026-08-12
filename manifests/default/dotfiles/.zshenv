# cargo/rustup bin on PATH (guarded: valid even before rustup's first
# toolchain install creates the directory)
case ":${PATH}:" in
*:"$HOME/.cargo/bin":*) ;;
*) [ -d "$HOME/.cargo/bin" ] && export PATH="$HOME/.cargo/bin:$PATH" ;;
esac
