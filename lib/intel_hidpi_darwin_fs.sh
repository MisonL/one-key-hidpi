#!/bin/bash

normalize_darwin_system_alias() {
    local path="$1"

    case "$path" in
    /tmp|/tmp/*)
        printf '/private%s\n' "$path"
        ;;
    /var|/var/*)
        printf '/private%s\n' "$path"
        ;;
    *)
        printf '%s\n' "$path"
        ;;
    esac
}

darwin_secure_fs() {
    local operation="$1"

    shift
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C /usr/bin/ruby -rfiddle -rfiddle/import -e '
        require "fcntl"
        require "open3"
        require "securerandom"

        module DarwinSecureFs
            extend self
            extend Fiddle::Importer

            dlload Fiddle::Handle::DEFAULT
            extern "int openat(int, const char*, int, int)"
            extern "int mkdirat(int, const char*, int)"
            extern "int unlinkat(int, const char*, int)"
            extern "int renameatx_np(int, const char*, int, const char*, unsigned int)"
            extern "int fcopyfile(int, int, void*, unsigned int)"
            extern "int fchmod(int, int)"
            extern "int fchown(int, int, int)"
            extern "int fsync(int)"
            extern "int kill(int, int)"
            extern "int close(int)"
            AT_FDCWD = -2
            O_NOFOLLOW = 0x00000100
            O_DIRECTORY = 0x00100000
            O_CLOEXEC = 0x01000000
            O_NONBLOCK = 0x00000004
            RENAME_SWAP = 0x00000002
            RENAME_EXCL = 0x00000004
            RENAME_NOFOLLOW_ANY = 0x00000010
            COPYFILE_ALL = 0x0000000f

            class Failure < StandardError
                def self.raise_failure
                    raise new
                end
            end

        def normalize(path)
            Failure.raise_failure unless path.start_with?("/")
            Failure.raise_failure if path.include?("\n") || path.include?("\r") || path.include?("\0")
            path = "/private#{path}" if path == "/tmp" || path.start_with?("/tmp/")
            path = "/private#{path}" if path == "/var" || path.start_with?("/var/")
            path
        end

        def path_components(path)
            normalized = normalize(path)
            components = normalized.split("/").reject(&:empty?)
            Failure.raise_failure if components.empty? || components.any? { |component| component == "." || component == ".." }
            components
        end

        def open_directory_path(path, create: false)
            fd = DarwinSecureFs.openat(
                AT_FDCWD,
                "/",
                Fcntl::O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
                0,
            )
            Failure.raise_failure if fd < 0

            current_path = ""
            path_components(path).each do |component|
                next_fd = DarwinSecureFs.openat(
                    fd,
                    component,
                    Fcntl::O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
                    0,
                )
                if next_fd < 0 && create
                    result = DarwinSecureFs.mkdirat(fd, component, 0o755)
                    Failure.raise_failure if result < 0 && Fiddle.last_error != Errno::EEXIST::Errno
                    next_fd = DarwinSecureFs.openat(
                        fd,
                        component,
                        Fcntl::O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
                        0,
                    )
                end
                Failure.raise_failure if next_fd < 0
                DarwinSecureFs.close(fd)
                fd = next_fd
                current_path = "#{current_path}/#{component}"
                # mkdirat does not return a descriptor. A later reopen cannot prove
                # that this name still denotes the directory we created, so do not
                # register it for destructive cleanup.
            end
            fd
        rescue StandardError
            DarwinSecureFs.close(fd) if defined?(fd) && fd && fd >= 0
            Failure.raise_failure
        end

        def open_directory_parent(path)
            components = path_components(path)
            name = components.pop
            Failure.raise_failure unless name
            parent_path = "/#{components.join("/")}"
            parent_path = "/" if parent_path.empty?
            [open_directory_path(parent_path), name]
        end

        def split_file_path(path)
            components = path_components(path)
            name = components.pop
            directory = "/#{components.join("/")}"
            directory = "/" if directory == "/"
            [directory, name]
        end

        def try_open_regular_file(directory_fd, name, writable: false)
            flags = (writable ? Fcntl::O_RDWR : Fcntl::O_RDONLY) | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW
            fd = DarwinSecureFs.openat(directory_fd, name, flags, 0)
            return nil if fd < 0
            stat = IO.for_fd(fd, autoclose: false).stat
            unless stat.file? && stat.nlink == 1
                DarwinSecureFs.close(fd)
                return nil
            end
            fd
        rescue StandardError
            DarwinSecureFs.close(fd) if defined?(fd) && fd && fd >= 0
            nil
        end

        def open_regular_file(directory_fd, name, writable: false)
            fd = try_open_regular_file(directory_fd, name, writable: writable)
            Failure.raise_failure unless fd
            fd
        end

        def try_open_entry(directory_fd, name)
            fd = DarwinSecureFs.openat(
                directory_fd,
                name,
                Fcntl::O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW,
                0,
            )
            return nil if fd < 0
            stat = IO.for_fd(fd, autoclose: false).stat
            unless stat.file? || stat.directory?
                DarwinSecureFs.close(fd)
                return nil
            end
            fd
        rescue StandardError
            DarwinSecureFs.close(fd) if defined?(fd) && fd && fd >= 0
            nil
        end

        def try_open_directory(directory_fd, name)
            fd = DarwinSecureFs.openat(
                directory_fd,
                name,
                Fcntl::O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
                0,
            )
            return :missing if fd < 0 && Fiddle.last_error == Errno::ENOENT::Errno
            return nil if fd < 0
            stat = IO.for_fd(fd, autoclose: false).stat
            unless stat.directory?
                DarwinSecureFs.close(fd)
                return nil
            end
            fd
        rescue StandardError
            DarwinSecureFs.close(fd) if defined?(fd) && fd && fd >= 0
            nil
        end

        def path_still_names_entry_fd?(directory_fd, name, fd)
            current_fd = try_open_entry(directory_fd, name)
            return false unless current_fd
            same = same_file?(current_fd, fd)
            DarwinSecureFs.close(current_fd)
            same
        rescue StandardError
            DarwinSecureFs.close(current_fd) if defined?(current_fd) && current_fd && current_fd >= 0
            false
        end

        def create_regular_file(directory_fd, name, mode)
            flags = Fcntl::O_RDWR | Fcntl::O_CREAT | Fcntl::O_EXCL | O_CLOEXEC | O_NOFOLLOW
            fd = DarwinSecureFs.openat(directory_fd, name, flags, mode)
            Failure.raise_failure if fd < 0
            stat = IO.for_fd(fd, autoclose: false).stat
            Failure.raise_failure unless stat.file? && stat.nlink == 1
            fd
        rescue StandardError
            DarwinSecureFs.close(fd) if defined?(fd) && fd && fd >= 0
            Failure.raise_failure
        end

        def sha256_fd(fd)
            io = IO.for_fd(fd, autoclose: false)
            io.rewind
            require "digest"
            digest = Digest::SHA256.new
            while (chunk = io.read(64 * 1024))
                digest.update(chunk)
            end
            io.rewind
            digest.hexdigest
        end

        def expected_sha256?(fd, expected_hash)
            Failure.raise_failure unless expected_hash.is_a?(String) && expected_hash.match?(/\A[0-9a-f]{64}\z/)
            sha256_fd(fd) == expected_hash
        end

        def same_file?(first_fd, second_fd)
            first = IO.for_fd(first_fd, autoclose: false).stat
            second = IO.for_fd(second_fd, autoclose: false).stat
            first.dev == second.dev && first.ino == second.ino
        end

        def file_identity(fd)
            stat = IO.for_fd(fd, autoclose: false).stat
            "#{stat.dev}:#{stat.ino}"
        end

        def file_snapshot(fd)
            "#{sha256_fd(fd)}|#{file_identity(fd)}"
        end

        def valid_identity_text?(expected_identity)
            expected_identity.is_a?(String) && expected_identity.match?(/\A[0-9]+:[0-9]+\z/)
        end

        def expected_identity?(fd, expected_identity)
            Failure.raise_failure unless valid_identity_text?(expected_identity)
            file_identity(fd) == expected_identity
        end

        def path_still_names_fd?(directory_fd, name, fd)
            current_fd = try_open_regular_file(directory_fd, name)
            return false unless current_fd
            same = same_file?(current_fd, fd)
            DarwinSecureFs.close(current_fd)
            same
        rescue StandardError
            DarwinSecureFs.close(current_fd) if defined?(current_fd) && current_fd && current_fd >= 0
            false
        end

        def copy_fd_to_new_file(source_fd, target_directory_fd, target_name)
            target_fd = create_regular_file(target_directory_fd, target_name, 0o600)
            IO.for_fd(source_fd, autoclose: false).rewind
            copy_result = DarwinSecureFs.fcopyfile(source_fd, target_fd, nil, COPYFILE_ALL)
            Failure.raise_failure if copy_result < 0
            IO.for_fd(source_fd, autoclose: false).rewind
            IO.for_fd(target_fd, autoclose: false).rewind
            target_fd
        rescue StandardError
            if defined?(target_fd) && target_fd && target_fd >= 0
                begin
                    partial_hash = sha256_fd(target_fd)
                    partial_identity = file_identity(target_fd)
                    removed = remove_verified_named_file(
                        target_directory_fd,
                        target_name,
                        target_fd,
                        partial_hash,
                        partial_identity,
                        "partial copy",
                    )
                    warn "error: partial copy cleanup failed; retained recovery artifact" unless removed
                rescue StandardError
                    warn "error: partial copy cleanup failed; retained recovery artifact"
                ensure
                    DarwinSecureFs.close(target_fd)
                end
            end
            Failure.raise_failure
        end

        def plist_output(fd, *arguments)
            io = IO.for_fd(fd, autoclose: false)
            io.close_on_exec = false
            output, status = Open3.capture2("/usr/bin/plutil", *arguments, "/dev/fd/#{fd}")
            Failure.raise_failure unless status.success?
            output
        rescue StandardError
            Failure.raise_failure
        end

        def verify_read_fd(directory_fd, name, fd, expected_hash, expected_identity)
            Failure.raise_failure unless path_still_names_fd?(directory_fd, name, fd)
            Failure.raise_failure unless expected_sha256?(fd, expected_hash)
            Failure.raise_failure unless expected_identity?(fd, expected_identity)
        end

        def read_lock_pid(fd)
            stat = IO.for_fd(fd, autoclose: false).stat
            Failure.raise_failure unless stat.size.positive? && stat.size <= 32
            io = IO.for_fd(fd, autoclose: false)
            io.rewind
            value = io.read
            match = /\A([1-9][0-9]*)\n\z/.match(value)
            Failure.raise_failure unless match
            Integer(match[1], 10)
        rescue StandardError
            Failure.raise_failure
        end

        def process_is_alive?(pid)
            result = DarwinSecureFs.kill(pid, 0)
            return true if result == 0

            errno = Fiddle.last_error
            return true if errno == Errno::EPERM::Errno
            return false if errno == Errno::ESRCH::Errno
            Failure.raise_failure
        end

        def unique_internal_name(prefix)
            ".one-key-hidpi-#{prefix}-#{Process.pid}-#{SecureRandom.hex(12)}"
        end

        def restore_quarantined_path(directory_fd, quarantine_name, original_name)
            result = DarwinSecureFs.renameatx_np(
                directory_fd,
                quarantine_name,
                directory_fd,
                original_name,
                RENAME_EXCL | RENAME_NOFOLLOW_ANY,
            )
            result == 0
        end

        def restore_quarantined_file(directory_fd, quarantine_name, original_name, quarantined_fd)
            return false unless path_still_names_entry_fd?(directory_fd, quarantine_name, quarantined_fd)
            return false unless restore_quarantined_path(directory_fd, quarantine_name, original_name)

            path_still_names_entry_fd?(directory_fd, original_name, quarantined_fd)
        end

        def restore_quarantined_directory(directory_fd, quarantine_name, original_name, quarantined_fd)
            return false unless path_still_names_entry_fd?(directory_fd, quarantine_name, quarantined_fd)
            return false unless restore_quarantined_path(directory_fd, quarantine_name, original_name)

            path_still_names_entry_fd?(directory_fd, original_name, quarantined_fd)
        end

        def remove_verified_named_file(directory_fd, name, named_fd, expected_hash, expected_identity, label)
            quarantine_name = unique_internal_name("quarantine")
            result = DarwinSecureFs.renameatx_np(
                directory_fd,
                name,
                directory_fd,
                quarantine_name,
                RENAME_EXCL | RENAME_NOFOLLOW_ANY,
            )
            return false if result < 0

            quarantine_fd = try_open_entry(directory_fd, quarantine_name)
            matches = quarantine_fd &&
                (IO.for_fd(quarantine_fd, autoclose: false).stat.file?) &&
                (IO.for_fd(quarantine_fd, autoclose: false).stat.nlink == 1) &&
                same_file?(quarantine_fd, named_fd) &&
                expected_sha256?(quarantine_fd, expected_hash) &&
                expected_identity?(quarantine_fd, expected_identity)
            unless matches
                restored = quarantine_fd &&
                    restore_quarantined_file(directory_fd, quarantine_name, name, quarantine_fd)
                DarwinSecureFs.close(quarantine_fd) if quarantine_fd
                warn "error: #{label} changed after quarantine; retained recovery artifact" unless restored
                return false
            end

            if path_still_names_fd?(directory_fd, quarantine_name, quarantine_fd) &&
               DarwinSecureFs.unlinkat(directory_fd, quarantine_name, 0) == 0
                DarwinSecureFs.close(quarantine_fd)
                return true
            end

            restored = restore_quarantined_file(directory_fd, quarantine_name, name, quarantine_fd)
            DarwinSecureFs.close(quarantine_fd)
            warn "error: #{label} cleanup failed; retained recovery artifact" unless restored
            false
        rescue StandardError
            if defined?(quarantine_fd) && quarantine_fd && quarantine_fd >= 0
                restored = restore_quarantined_file(directory_fd, quarantine_name, name, quarantine_fd)
                DarwinSecureFs.close(quarantine_fd)
                warn "error: #{label} cleanup raised; retained recovery artifact" unless restored
            end
            false
        end

        def remove_verified_empty_directory(directory_fd, name, named_fd, expected_identity, label)
            quarantine_name = unique_internal_name("directory-quarantine")
            result = DarwinSecureFs.renameatx_np(
                directory_fd,
                name,
                directory_fd,
                quarantine_name,
                RENAME_EXCL | RENAME_NOFOLLOW_ANY,
            )
            return false if result < 0

            quarantine_fd = try_open_directory(directory_fd, quarantine_name)
            quarantine_fd = nil if quarantine_fd == :missing
            matches = quarantine_fd &&
                same_file?(quarantine_fd, named_fd) &&
                expected_identity?(quarantine_fd, expected_identity)
            unless matches
                restored = quarantine_fd &&
                    restore_quarantined_directory(directory_fd, quarantine_name, name, quarantine_fd)
                DarwinSecureFs.close(quarantine_fd) if quarantine_fd
                warn "error: #{label} changed after quarantine; retained recovery artifact" unless restored
                return false
            end

            removal_result = DarwinSecureFs.unlinkat(directory_fd, quarantine_name, 0x00000080)
            removal_errno = Fiddle.last_error
            if removal_result == 0
                DarwinSecureFs.close(quarantine_fd)
                return true
            end

            restored = restore_quarantined_directory(directory_fd, quarantine_name, name, quarantine_fd)
            DarwinSecureFs.close(quarantine_fd)
            if removal_errno == Errno::ENOTEMPTY::Errno && restored
                warn "error: #{label} was not empty; retained directory"
                return false
            end

            warn "error: #{label} cleanup failed; retained recovery artifact" unless restored
            false
        rescue StandardError
            if defined?(quarantine_fd) && quarantine_fd && quarantine_fd >= 0
                restored = restore_quarantined_directory(directory_fd, quarantine_name, name, quarantine_fd)
                DarwinSecureFs.close(quarantine_fd)
                warn "error: #{label} cleanup raised; retained recovery artifact" unless restored
            end
            false
        end

        def remove_stale_lock(directory_fd, lock_name, lock_fd, expected_hash, expected_identity)
            remove_verified_named_file(
                directory_fd,
                lock_name,
                lock_fd,
                expected_hash,
                expected_identity,
                "stale lock",
            )
        end

        def try_create_lock(directory_fd, lock_name, pid)
            flags = Fcntl::O_RDWR | Fcntl::O_CREAT | Fcntl::O_EXCL | O_CLOEXEC | O_NOFOLLOW
            fd = DarwinSecureFs.openat(directory_fd, lock_name, flags, 0o600)
            return nil if fd < 0 && Fiddle.last_error == Errno::EEXIST::Errno
            Failure.raise_failure if fd < 0
            stat = IO.for_fd(fd, autoclose: false).stat
            Failure.raise_failure unless stat.file? && stat.nlink == 1
            io = IO.for_fd(fd, autoclose: false)
            io.write("#{pid}\n")
            io.flush
            Failure.raise_failure if DarwinSecureFs.fsync(fd) < 0
            Failure.raise_failure unless path_still_names_fd?(directory_fd, lock_name, fd)
            fd
        rescue StandardError
            DarwinSecureFs.close(fd) if defined?(fd) && fd && fd >= 0
            Failure.raise_failure
        end

            def run(arguments)
            operation = arguments.shift
        case operation
        when "ensure-directory"
            directory_fd = open_directory_path(arguments.fetch(0), create: true)
            DarwinSecureFs.close(directory_fd)
        when "install"
            source_path, target_path, expected_hash, expected_identity = arguments
            source_directory, source_name = split_file_path(source_path)
            target_directory, target_name = split_file_path(target_path)
            source_directory_fd = open_directory_path(source_directory)
            target_directory_fd = open_directory_path(target_directory)
            source_fd = open_regular_file(source_directory_fd, source_name)
            Failure.raise_failure unless expected_sha256?(source_fd, expected_hash)
            Failure.raise_failure unless expected_identity?(source_fd, expected_identity)
            installed_fd = copy_fd_to_new_file(source_fd, target_directory_fd, target_name)
            target_fd = open_regular_file(target_directory_fd, target_name)
            installed_matches = same_file?(installed_fd, target_fd) &&
                expected_sha256?(target_fd, expected_hash) &&
                path_still_names_fd?(target_directory_fd, target_name, installed_fd)
            unless installed_matches
                DarwinSecureFs.close(target_fd)
                DarwinSecureFs.close(installed_fd)
                DarwinSecureFs.close(source_fd)
                DarwinSecureFs.close(target_directory_fd)
                DarwinSecureFs.close(source_directory_fd)
                warn "error: installation verification failed after target creation; manual inspection required"
                exit 2
            end
            puts file_snapshot(installed_fd)
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(installed_fd)
            DarwinSecureFs.close(source_fd)
            DarwinSecureFs.close(target_directory_fd)
            DarwinSecureFs.close(source_directory_fd)
        when "hash"
            target_path = arguments.fetch(0)
            target_directory, target_name = split_file_path(target_path)
            target_directory_fd = open_directory_path(target_directory)
            target_fd = open_regular_file(target_directory_fd, target_name)
            puts sha256_fd(target_fd)
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(target_directory_fd)
        when "identity"
            target_path = arguments.fetch(0)
            target_directory, target_name = split_file_path(target_path)
            target_directory_fd = open_directory_path(target_directory)
            target_fd = open_regular_file(target_directory_fd, target_name)
            puts file_identity(target_fd)
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(target_directory_fd)
        when "directory-identity"
            target_path = arguments.fetch(0)
            target_directory, target_name = split_file_path(target_path)
            target_directory_fd = open_directory_path(target_directory)
            target_fd = try_open_directory(target_directory_fd, target_name)
            Failure.raise_failure unless target_fd && target_fd != :missing
            puts file_identity(target_fd)
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(target_directory_fd)
        when "snapshot"
            target_path = arguments.fetch(0)
            target_directory, target_name = split_file_path(target_path)
            target_directory_fd = open_directory_path(target_directory)
            target_fd = open_regular_file(target_directory_fd, target_name)
            puts file_snapshot(target_fd)
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(target_directory_fd)
        when "read-plist"
            target_path, expected_hash, expected_identity, *plutil_args = arguments
            target_directory, target_name = split_file_path(target_path)
            target_directory_fd = open_directory_path(target_directory)
            target_fd = open_regular_file(target_directory_fd, target_name)
            Failure.raise_failure unless expected_sha256?(target_fd, expected_hash)
            Failure.raise_failure unless expected_identity?(target_fd, expected_identity)
            output = plist_output(target_fd, *plutil_args)
            verify_read_fd(target_directory_fd, target_name, target_fd, expected_hash, expected_identity)
            print output
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(target_directory_fd)
        when "plutil"
            target_path, expected_hash, expected_identity, *plutil_args = arguments
            target_directory, target_name = split_file_path(target_path)
            target_directory_fd = open_directory_path(target_directory)
            target_fd = open_regular_file(target_directory_fd, target_name, writable: true)
            Failure.raise_failure unless expected_sha256?(target_fd, expected_hash)
            Failure.raise_failure unless expected_identity?(target_fd, expected_identity)
            plist_output(target_fd, *plutil_args)
            Failure.raise_failure unless path_still_names_fd?(target_directory_fd, target_name, target_fd)
            Failure.raise_failure unless expected_identity?(target_fd, expected_identity)
            final_hash = sha256_fd(target_fd)
            puts "#{final_hash}|#{file_identity(target_fd)}"
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(target_directory_fd)
        when "metadata"
            target_path, expected_hash, expected_identity, mode_text, owner_text, group_text = arguments
            mode = Integer(mode_text, 8)
            target_directory, target_name = split_file_path(target_path)
            target_directory_fd = open_directory_path(target_directory)
            target_fd = open_regular_file(target_directory_fd, target_name, writable: true)
            Failure.raise_failure unless expected_sha256?(target_fd, expected_hash)
            Failure.raise_failure unless expected_identity?(target_fd, expected_identity)
            Failure.raise_failure if DarwinSecureFs.fchmod(target_fd, mode) < 0
            if !owner_text.empty? || !group_text.empty?
                Failure.raise_failure if owner_text.empty? || group_text.empty?
                Failure.raise_failure if DarwinSecureFs.fchown(target_fd, Integer(owner_text, 10), Integer(group_text, 10)) < 0
            end
            Failure.raise_failure unless expected_sha256?(target_fd, expected_hash)
            Failure.raise_failure unless expected_identity?(target_fd, expected_identity)
            Failure.raise_failure unless path_still_names_fd?(target_directory_fd, target_name, target_fd)
            puts "#{sha256_fd(target_fd)}|#{file_identity(target_fd)}"
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(target_directory_fd)
        when "replace"
            source_path, target_path, expected_source_hash, expected_source_identity, expected_target_hash, expected_target_identity = arguments
            source_directory, source_name = split_file_path(source_path)
            target_directory, target_name = split_file_path(target_path)
            source_directory_fd = open_directory_path(source_directory)
            target_directory_fd = open_directory_path(target_directory)
            source_fd = open_regular_file(source_directory_fd, source_name)
            target_fd = open_regular_file(target_directory_fd, target_name)
            Failure.raise_failure unless expected_sha256?(source_fd, expected_source_hash)
            Failure.raise_failure unless expected_identity?(source_fd, expected_source_identity)
            Failure.raise_failure unless expected_sha256?(target_fd, expected_target_hash)
            Failure.raise_failure unless expected_identity?(target_fd, expected_target_identity)
            Failure.raise_failure unless path_still_names_fd?(target_directory_fd, target_name, target_fd)
            staged_name = ".one-key-hidpi-stage-#{Process.pid}-#{SecureRandom.hex(12)}"
            staged_fd = copy_fd_to_new_file(source_fd, target_directory_fd, staged_name)
            Failure.raise_failure unless expected_sha256?(staged_fd, expected_source_hash)
            staged_identity = file_identity(staged_fd)
            staged_path_matches = path_still_names_fd?(target_directory_fd, staged_name, staged_fd) &&
                expected_sha256?(staged_fd, expected_source_hash)
            target_path_matches = path_still_names_fd?(target_directory_fd, target_name, target_fd) &&
                expected_sha256?(target_fd, expected_target_hash)
            unless staged_path_matches && target_path_matches
                staged_removed = false
                if staged_path_matches
                    staged_removed = remove_verified_named_file(
                        target_directory_fd,
                        staged_name,
                        staged_fd,
                        expected_source_hash,
                        staged_identity,
                        "staged replacement candidate",
                    )
                end
                DarwinSecureFs.close(staged_fd)
                DarwinSecureFs.close(target_fd)
                DarwinSecureFs.close(source_fd)
                DarwinSecureFs.close(target_directory_fd)
                DarwinSecureFs.close(source_directory_fd)
                if staged_path_matches && staged_removed
                    warn "error: replacement did not start because target changed before swap"
                    exit 1
                end
                warn "error: replacement did not start and staged recovery artifact was retained"
                exit 2
            end
            result = DarwinSecureFs.renameatx_np(
                target_directory_fd,
                staged_name,
                target_directory_fd,
                target_name,
                RENAME_SWAP | RENAME_NOFOLLOW_ANY,
            )
            if result < 0
                staged_removed = remove_verified_named_file(
                    target_directory_fd,
                    staged_name,
                    staged_fd,
                    expected_source_hash,
                    staged_identity,
                    "staged replacement candidate",
                )
                DarwinSecureFs.close(staged_fd)
                DarwinSecureFs.close(target_fd)
                DarwinSecureFs.close(source_fd)
                DarwinSecureFs.close(target_directory_fd)
                DarwinSecureFs.close(source_directory_fd)
                if staged_removed
                    exit 1
                end
                warn "error: replacement did not start and staged recovery artifact was retained"
                exit 2
            end
            new_target_fd = try_open_regular_file(target_directory_fd, target_name)
            moved_previous_fd = try_open_regular_file(target_directory_fd, staged_name)
            target_matches = new_target_fd &&
                same_file?(new_target_fd, staged_fd) &&
                expected_sha256?(new_target_fd, expected_source_hash) &&
                path_still_names_fd?(target_directory_fd, target_name, new_target_fd)
            previous_matches = moved_previous_fd &&
                same_file?(moved_previous_fd, target_fd) &&
                expected_sha256?(moved_previous_fd, expected_target_hash) &&
                expected_identity?(moved_previous_fd, expected_target_identity) &&
                path_still_names_fd?(target_directory_fd, staged_name, moved_previous_fd)
            unless target_matches && previous_matches
                DarwinSecureFs.close(new_target_fd) if new_target_fd
                DarwinSecureFs.close(moved_previous_fd) if moved_previous_fd
                DarwinSecureFs.close(staged_fd)
                DarwinSecureFs.close(target_fd)
                DarwinSecureFs.close(source_fd)
                DarwinSecureFs.close(target_directory_fd)
                DarwinSecureFs.close(source_directory_fd)
                warn "error: replacement verification failed after swap; retained target and staged path for manual inspection"
                exit 2
            end
            installed_snapshot = file_snapshot(new_target_fd)
            displaced_removed = remove_verified_named_file(
                target_directory_fd,
                staged_name,
                moved_previous_fd,
                expected_target_hash,
                expected_target_identity,
                "displaced target",
            )
            DarwinSecureFs.close(new_target_fd)
            DarwinSecureFs.close(moved_previous_fd)
            DarwinSecureFs.close(staged_fd)
            unless displaced_removed
                DarwinSecureFs.close(target_fd)
                DarwinSecureFs.close(source_fd)
                DarwinSecureFs.close(target_directory_fd)
                DarwinSecureFs.close(source_directory_fd)
                warn "error: replacement completed but displaced target cleanup failed; manual inspection required"
                exit 2
            end
            puts installed_snapshot
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(source_fd)
            DarwinSecureFs.close(target_directory_fd)
            DarwinSecureFs.close(source_directory_fd)
        when "remove"
            target_path, expected_hash, expected_identity = arguments
            target_directory, target_name = split_file_path(target_path)
            target_directory_fd = open_directory_path(target_directory)
            target_fd = open_regular_file(target_directory_fd, target_name)
            Failure.raise_failure unless expected_sha256?(target_fd, expected_hash)
            Failure.raise_failure unless expected_identity?(target_fd, expected_identity)
            removed = remove_verified_named_file(
                target_directory_fd,
                target_name,
                target_fd,
                expected_hash,
                expected_identity,
                "file removal",
            )
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(target_directory_fd)
            Failure.raise_failure unless removed
        when "rmdir-verified"
            path, expected_identity = arguments
            Failure.raise_failure unless valid_identity_text?(expected_identity)
            directory_fd, name = open_directory_parent(path)
            target_fd = try_open_directory(directory_fd, name)
            if target_fd == :missing
                DarwinSecureFs.close(directory_fd)
                exit 0
            end
            Failure.raise_failure unless target_fd
            Failure.raise_failure unless expected_identity?(target_fd, expected_identity)
            Failure.raise_failure unless path_still_names_entry_fd?(directory_fd, name, target_fd)
            removed = remove_verified_empty_directory(
                directory_fd,
                name,
                target_fd,
                expected_identity,
                "directory cleanup",
            )
            DarwinSecureFs.close(target_fd)
            DarwinSecureFs.close(directory_fd)
            Failure.raise_failure unless removed
        when "lock"
            lock_path, pid_text = arguments
            Failure.raise_failure unless pid_text.match?(/\A[1-9][0-9]*\z/)
            lock_directory, lock_name = split_file_path(lock_path)
            lock_directory_fd = open_directory_path(lock_directory)
            lock_fd = try_create_lock(lock_directory_fd, lock_name, Integer(pid_text, 10))
            if lock_fd.nil?
                existing_fd = open_regular_file(lock_directory_fd, lock_name)
                existing_hash = sha256_fd(existing_fd)
                existing_identity = file_identity(existing_fd)
                existing_pid = read_lock_pid(existing_fd)
                if process_is_alive?(existing_pid)
                    DarwinSecureFs.close(existing_fd)
                    DarwinSecureFs.close(lock_directory_fd)
                    exit 2
                end
                Failure.raise_failure unless remove_stale_lock(lock_directory_fd, lock_name, existing_fd, existing_hash, existing_identity)
                DarwinSecureFs.close(existing_fd)
                lock_fd = try_create_lock(lock_directory_fd, lock_name, Integer(pid_text, 10))
                Failure.raise_failure if lock_fd.nil?
            end
            puts file_snapshot(lock_fd)
            DarwinSecureFs.close(lock_fd)
            DarwinSecureFs.close(lock_directory_fd)
        else
            Failure.raise_failure
        end
        0
        rescue Failure
            1
        end
        end

        exit DarwinSecureFs.run(ARGV)
    ' "$operation" "$@"
}

darwin_ensure_directory_path() {
    darwin_secure_fs ensure-directory "$1"
}

darwin_install_file_without_replacement() {
    local source_path="$1"
    local target_path="$2"
    local expected_hash="$3"
    local expected_identity="$4"

    darwin_secure_fs install "$source_path" "$target_path" "$expected_hash" "$expected_identity"
}

darwin_sha256_file() {
    darwin_secure_fs hash "$1"
}

darwin_file_identity() {
    darwin_secure_fs identity "$1"
}

darwin_directory_identity() {
    darwin_secure_fs directory-identity "$1"
}

darwin_file_snapshot() {
    darwin_secure_fs snapshot "$1"
}

darwin_read_plist_file() {
    local target_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"

    shift 3
    darwin_secure_fs read-plist "$target_path" "$expected_hash" "$expected_identity" "$@"
}

darwin_replace_file() {
    local source_path="$1"
    local target_path="$2"
    local expected_source_hash="$3"
    local expected_source_identity="$4"
    local expected_target_hash="$5"
    local expected_target_identity="$6"

    darwin_secure_fs replace "$source_path" "$target_path" "$expected_source_hash" "$expected_source_identity" "$expected_target_hash" "$expected_target_identity"
}

darwin_remove_file_if_unchanged() {
    darwin_secure_fs remove "$1" "$2" "$3"
}

darwin_remove_empty_directory_if_unchanged() {
    local path="$1"
    local expected_identity="$2"

    darwin_secure_fs rmdir-verified "$path" "$expected_identity"
}

darwin_acquire_lock() {
    darwin_secure_fs lock "$1" "$2"
}

darwin_plutil_file() {
    local target_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"

    shift 3
    darwin_secure_fs plutil "$target_path" "$expected_hash" "$expected_identity" "$@"
}

darwin_set_file_metadata() {
    darwin_secure_fs metadata "$1" "$2" "$3" "$4" "$5" "$6"
}
