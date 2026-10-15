#include "storage/kv_store.hpp"

#include <rocksdb/db.h>
#include <rocksdb/iterator.h>

#include <cassert>
#include <utility>

namespace acmedb::storage {

// Shared, heap-allocated state backing a single prefix scan. It owns the
// RocksDB iterator and remembers the prefix so the iterator can stop once the
// keys no longer match. The owning PrefixRange holds it in a unique_ptr; the
// PrefixIterator only points at it.
struct detail::IteratorState {
    std::unique_ptr<rocksdb::Iterator> it;
    std::string prefix;
    bool failed = false;

    explicit IteratorState(std::unique_ptr<rocksdb::Iterator> iterator, std::string p)
        : it(std::move(iterator)), prefix(std::move(p)) {}

    // After a successful seek, Valid() means the current key still starts with
    // the prefix. An error transition is recorded so callers can surface it.
    [[nodiscard]] bool valid() const {
        return it->Valid() && key_starts_with_prefix();
    }

    [[nodiscard]] bool key_starts_with_prefix() const {
        const auto k = it->key();
        if (k.size() < prefix.size()) {
            return false;
        }
        return std::string_view(k.data(), prefix.size()) == prefix;
    }
};

// ---------------------------------------------------------------------------
// PrefixIterator
// ---------------------------------------------------------------------------

PrefixIterator::PrefixIterator(detail::IteratorState* state) noexcept : state_(state) {
    if (state_ == nullptr) {
        at_end_ = true;
        return;
    }
    seek_to_prefix_start();
}

void PrefixIterator::seek_to_prefix_start() {
    state_->it->Seek(rocksdb::Slice(state_->prefix));
    at_end_ = !state_->valid();
    if (state_->it->status().IsNotFound()) {
        // A missing entry during seek is not an error for a prefix scan.
        at_end_ = true;
    }
}

PrefixIterator::reference PrefixIterator::operator*() const noexcept {
    assert(state_ != nullptr && !at_end_);
    const auto k = state_->it->key();
    const auto v = state_->it->value();
    return {std::string_view(k.data(), k.size()), std::string_view(v.data(), v.size())};
}

PrefixIterator& PrefixIterator::operator++() {
    assert(state_ != nullptr && !at_end_);
    state_->it->Next();
    at_end_ = !state_->valid();
    return *this;
}

// ---------------------------------------------------------------------------
// PrefixRange
// ---------------------------------------------------------------------------

PrefixRange::PrefixRange() noexcept = default;
PrefixRange::PrefixRange(std::unique_ptr<detail::IteratorState> state) noexcept
    : state_(std::move(state)) {}
PrefixRange::PrefixRange(PrefixRange&&) noexcept = default;
PrefixRange& PrefixRange::operator=(PrefixRange&&) noexcept = default;
PrefixRange::~PrefixRange() = default;

PrefixIterator PrefixRange::begin() const {
    return PrefixIterator(state_.get());
}

bool PrefixRange::ok() const noexcept {
    return state_ == nullptr || !state_->failed;
}

KvError PrefixRange::error() const noexcept {
    return KvError::IteratorFailed;
}

// ---------------------------------------------------------------------------
// KvStore
// ---------------------------------------------------------------------------

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

std::expected<std::optional<std::string>, KvError> KvStore::get(std::string_view key) const {
    std::string value;
    const auto status = impl_->db->Get(
        rocksdb::ReadOptions{},
        rocksdb::Slice(key.data(), key.size()),
        &value
    );
    if (status.IsNotFound()) {
        return std::optional<std::string>{};
    }
    if (!status.ok()) {
        return std::unexpected(KvError::ReadFailed);
    }
    return std::optional<std::string>{std::move(value)};
}

std::expected<bool, KvError> KvStore::exists(std::string_view key) const {
    std::string value;
    const auto status = impl_->db->Get(
        rocksdb::ReadOptions{},
        rocksdb::Slice(key.data(), key.size()),
        &value
    );
    if (status.IsNotFound()) {
        return false;
    }
    if (!status.ok()) {
        return std::unexpected(KvError::ReadFailed);
    }
    return true;
}

std::expected<void, KvError> KvStore::del(std::string_view key) {
    const auto status = impl_->db->Delete(
        rocksdb::WriteOptions{},
        rocksdb::Slice(key.data(), key.size())
    );
    if (!status.ok()) {
        return std::unexpected(KvError::DeleteFailed);
    }
    return {};
}

std::expected<PrefixRange, KvError> KvStore::scan_prefix(std::string_view prefix) const {
    std::unique_ptr<rocksdb::Iterator> it(
        impl_->db->NewIterator(rocksdb::ReadOptions{})
    );
    if (!it) {
        return std::unexpected(KvError::IteratorFailed);
    }
    auto state = std::make_unique<detail::IteratorState>(std::move(it), std::string(prefix));
    return PrefixRange(std::move(state));
}

std::expected<std::size_t, KvError> KvStore::count_prefix(std::string_view prefix) const {
    auto range = scan_prefix(prefix);
    if (!range) {
        return std::unexpected(range.error());
    }
    std::size_t count = 0;
    for ([[maybe_unused]] const auto& entry : *range) {
        ++count;
    }
    if (!range->ok()) {
        return std::unexpected(range->error());
    }
    return count;
}

} // namespace acmedb::storage
