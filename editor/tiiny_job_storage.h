#ifndef TIINY_JOB_STORAGE_H
#define TIINY_JOB_STORAGE_H

#include "core/object/ref_counted.h"

// The lock file is permanent: removing a locked inode would permit another
// process to lock a different inode at the same path.
class TiinyJobStorage : public RefCounted {
	GDCLASS(TiinyJobStorage, RefCounted);

	int lock_fd = -1;
	String path;

protected:
	static void _bind_methods();

public:
	bool acquire(const String &p_path);
	bool commit(const String &p_json);
	String link_exclusive(const String &p_root, const String &p_source, const String &p_destination);
	bool same_file(const String &p_root, const String &p_source, const String &p_destination);
	void release();
	~TiinyJobStorage();
};

#endif
