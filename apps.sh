# Apps that can be packed into a root module.
# MODULE_ID is the same as in morphe-module, so the module installs over the one built there.
# STOCK_SIG: SHA-256 of the original (Google) signing certificate, the stock apk is checked against it.

app_YouTube() {
	PKG=com.google.android.youtube
	MODULE_ID=youtube-dualvot-arm64
	MODULE_NAME="YouTube DualVoT"
	FILE_PREFIX=youtube-dualvot
	ARCH=arm64-v8a
	STOCK_SIG=3d7a1223019aa39d9ea0e3436ab7c0896bfb4fb679f4de5fe7c23f326c8f994a
}

app_GooglePhotos() {
	PKG=com.google.android.apps.photos
	MODULE_ID=googlephotos-devanced-arm64
	MODULE_NAME="GooglePhotos DeVanced"
	FILE_PREFIX=googlephotos-devanced
	ARCH=arm64-v8a
	STOCK_SIG=3d7a1223019aa39d9ea0e3436ab7c0896bfb4fb679f4de5fe7c23f326c8f994a
}
