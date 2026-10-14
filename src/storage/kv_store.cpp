#include "storage/kv_store.hpp"

#include <rocksdb/db.h>

#include <utility>

namespace acmedb::storage {

struct KvStore::Impl {
    std::unique_ptr<rocksdb::DB> db;
};

KvStore::KvStore(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
KvStore::KvStore(KvStore&&) noexcept = default;
KvStore& KvStore::operator=(KvStore&&) noexcept = default;
KvStore::~KvStore() = default;

std::expected<KvStore, KvError> KvStore::open(const std::filesystem::path& path) {
    rocksdb::Options options;
    options.create_if_missing = true;

    std::unique_ptr<rocksdb::DB> db;
    const auto status = rocksdb::DB::Open(options, path.string(), &db);
    if (!status.ok()) {
        return std::unexpected(KvError::OpenFailed);
    }

    return KvStore(std::make_unique<Impl>(Impl{std::move(db)}));
}

std::expected<void, KvError> KvStore::put(std::string_view key, std::string_view value) {
    const auto status = impl_->db->Put(
        rocksdb::WriteOptions{},
        rocksdb::Slice(key.data(), key.size()),
        rocksdb::Slice(value.data(), value.size())
    );
    if (!status.ok()) {
        return std::unexpected(KvError::WriteFailed);
    }
    return {};
}

std::expected<std::string, KvError> KvStore::get(std::string_view key) const {
    std::string value;
    const auto status = impl_->db->Get(
        rocksdb::ReadOptions{},
        rocksdb::Slice(key.data(), key.size()),
        &value
    );
    if (!status.ok()) {
        return std::unexpected(KvError::ReadFailed);
    }
    return value;
}

} // namespace acmedb::storage
