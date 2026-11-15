#include "tiiny_job_storage.h"

#include "core/object/class_db.h"

#ifdef UNIX_ENABLED
#include <cerrno>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

// Resolve project-relative components without following directory symlinks.
// The project root itself must be the canonical, trusted root selected by the
// editor. Returns an owned parent descriptor and a single basename.
static int open_parent(const String &p_root, const String &p_relative, String &r_name) {
	if (!p_root.is_absolute_path() || p_relative.is_empty() || p_relative.is_absolute_path() || p_relative.contains("\\")) {
		return -1;
	}
	Vector<String> parts = p_relative.split("/", true);
	if (parts.is_empty()) {
		return -1;
	}
	for (const String &part : parts) {
		if (part.is_empty() || part == "." || part == "..") {
			return -1;
		}
	}
	CharString root = p_root.utf8();
	int fd = ::open(root.get_data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0) {
		return -1;
	}
	for (int i = 0; i < parts.size() - 1; i++) {
		CharString component = parts[i].utf8();
		int next = ::openat(fd, component.get_data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
		::close(fd);
		if (next < 0) {
			return -1;
		}
		fd = next;
	}
	r_name = parts[parts.size() - 1];
	return fd;
}
#endif

void TiinyJobStorage::_bind_methods() {
	ClassDB::bind_method(D_METHOD("acquire", "path"), &TiinyJobStorage::acquire);
	ClassDB::bind_method(D_METHOD("commit", "json"), &TiinyJobStorage::commit);
	ClassDB::bind_method(D_METHOD("link_exclusive", "root", "source", "destination"), &TiinyJobStorage::link_exclusive);
	ClassDB::bind_method(D_METHOD("same_file", "root", "source", "destination"), &TiinyJobStorage::same_file);
	ClassDB::bind_method(D_METHOD("release"), &TiinyJobStorage::release);
}

String TiinyJobStorage::link_exclusive(const String &p_root, const String &p_source, const String &p_destination) {
#ifdef UNIX_ENABLED
	if (lock_fd == -1) {
		return "unavailable";
	}
	String source_name, destination_name;
	int source_dir = open_parent(p_root, p_source, source_name);
	int destination_dir = open_parent(p_root, p_destination, destination_name);
	if (source_dir < 0 || destination_dir < 0) {
		if (source_dir >= 0) {
			::close(source_dir);
		}
		if (destination_dir >= 0) {
			::close(destination_dir);
		}
		return "invalid_path";
	}
	CharString source = source_name.utf8();
	CharString destination = destination_name.utf8();
	struct stat before, after;
	String result = "invalid_source";
	int source_fd = ::openat(source_dir, source.get_data(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (source_fd >= 0 && fstat(source_fd, &before) == 0 && S_ISREG(before.st_mode) && fsync(source_fd) == 0) {
		if (linkat(source_dir, source.get_data(), destination_dir, destination.get_data(), 0) != 0) {
			// On an I/O error, particularly on a network filesystem, failure
			// does not prove whether the directory entry was installed.
			result = errno == EEXIST ? "conflict" : "uncertain";
		} else if (fstatat(destination_dir, destination.get_data(), &after, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(after.st_mode) || before.st_dev != after.st_dev || before.st_ino != after.st_ino || fsync(destination_dir) != 0) {
			// A link exists or might exist. The journal must remain unresolved.
			result = "uncertain";
		} else {
			result = "published";
		}
	}
	if (source_fd >= 0) {
		::close(source_fd);
	}
	::close(source_dir);
	::close(destination_dir);
	return result;
#else
	return "unavailable";
#endif
}

bool TiinyJobStorage::same_file(const String &p_root, const String &p_source, const String &p_destination) {
#ifdef UNIX_ENABLED
	if (lock_fd == -1) {
		return false;
	}
	String source_name, destination_name;
	int source_dir = open_parent(p_root, p_source, source_name);
	int destination_dir = open_parent(p_root, p_destination, destination_name);
	struct stat source_stat, destination_stat;
	bool same = source_dir >= 0 && destination_dir >= 0 && fstatat(source_dir, source_name.utf8().get_data(), &source_stat, AT_SYMLINK_NOFOLLOW) == 0 && fstatat(destination_dir, destination_name.utf8().get_data(), &destination_stat, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(source_stat.st_mode) && S_ISREG(destination_stat.st_mode) && source_stat.st_dev == destination_stat.st_dev && source_stat.st_ino == destination_stat.st_ino;
	if (source_dir >= 0) {
		::close(source_dir);
	}
	if (destination_dir >= 0) {
		::close(destination_dir);
	}
	return same;
#else
	return false;
#endif
}

bool TiinyJobStorage::acquire(const String &p_path) {
#ifdef UNIX_ENABLED
	if (lock_fd != -1 || !p_path.is_absolute_path()) {
		return false;
	}
	CharString lock_path = (p_path + ".lock").utf8();
	int fd = ::open(lock_path.get_data(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0) {
		return false;
	}
	if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
		::close(fd);
		return false;
	}
	lock_fd = fd;
	path = p_path;
	return true;
#else
	// Do not use a process-local substitute on unsupported platforms.
	return false;
#endif
}

bool TiinyJobStorage::commit(const String &p_json) {
#ifdef UNIX_ENABLED
	if (lock_fd == -1) {
		return false;
	}
	CharString temp_path = (path + ".tmp").utf8();
	CharString final_path = path.utf8();
	CharString directory = path.get_base_dir().utf8();
	// A leftover temp file represents an uncommitted write. The exclusive
	// project lock ensures no other writer can be using it.
	if (::unlink(temp_path.get_data()) != 0 && errno != ENOENT) {
		return false;
	}
	int fd = ::open(temp_path.get_data(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0) {
		return false;
	}
	CharString bytes = p_json.utf8();
	int64_t offset = 0;
	bool ok = true;
	while (offset < bytes.length()) {
		ssize_t count = ::write(fd, bytes.get_data() + offset, bytes.length() - offset);
		if (count < 0 && errno == EINTR) {
			continue;
		}
		if (count <= 0) {
			ok = false;
			break;
		}
		offset += count;
	}
	if (ok && fsync(fd) != 0) {
		ok = false;
	}
	if (::close(fd) != 0) {
		ok = false;
	}
	if (!ok || ::rename(temp_path.get_data(), final_path.get_data()) != 0) {
		::unlink(temp_path.get_data());
		return false;
	}
	int dir_fd = ::open(directory.get_data(), O_RDONLY | O_CLOEXEC);
	if (dir_fd < 0) {
		return false;
	}
	ok = fsync(dir_fd) == 0;
	::close(dir_fd);
	return ok;
#else
	return false;
#endif
}

void TiinyJobStorage::release() {
#ifdef UNIX_ENABLED
	if (lock_fd != -1) {
		flock(lock_fd, LOCK_UN);
		::close(lock_fd);
		lock_fd = -1;
	}
#endif
	path = String();
}

TiinyJobStorage::~TiinyJobStorage() {
	release();
}
