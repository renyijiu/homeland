require "auto-space"

CORRECT_CHARS = [
  ["［", "["],
  ["］", "]"],
  ["【", "["],
  ["】", "]"],
  ["（", "("],
  ["）", ")"]
]

class Topic < ApplicationRecord
  include MarkdownBody
  include SoftDelete
  include Mentionable
  include Closeable
  include Searchable
  include MentionTopic
  include UserAvatarDelegate

  # 临时存储检测用户是否读过的结果
  attr_accessor :read_state, :admin_editing

  belongs_to :user, inverse_of: :topics, counter_cache: true
  belongs_to :team, counter_cache: true
  belongs_to :node, counter_cache: true
  belongs_to :last_reply_user, class_name: "User"
  belongs_to :last_reply, class_name: "Reply"
  has_many :replies, dependent: :destroy

  validates :user_id, :title, :body, :node_id, presence: true

  counter :hits, default: 0
  list :seven_days_hits, maxlength: 7
  list :recent_day_hits, maxlength: 24
  value :last_update_time_for_hits

  delegate :login, to: :user, prefix: true, allow_nil: true
  delegate :body, to: :last_reply, prefix: true, allow_nil: true

  # scopes
  scope :last_actived,       -> { order(last_active_mark: :desc) }
  scope :suggest,            -> { where("suggested_at IS NOT NULL").order(suggested_at: :desc) }
  scope :without_suggest,    -> { where(suggested_at: nil) }
  scope :high_likes,         -> { order(likes_count: :desc).order(id: :desc) }
  scope :high_replies,       -> { order(replies_count: :desc).order(id: :desc) }
  scope :no_reply,           -> { where(replies_count: 0) }
  scope :popular,            -> { where("likes_count > 5") }
  scope :excellent,          -> { where("excellent >= 1") }
  scope :without_hide_nodes, -> { exclude_column_ids("node_id", Topic.topic_index_hide_node_ids) }

  scope :without_node_ids,   ->(ids) { exclude_column_ids("node_id", ids) }
  scope :without_users,      ->(ids) { exclude_column_ids("user_id", ids) }
  scope :exclude_column_ids, ->(column, ids) { ids.empty? ? all : where.not(column => ids) }

  scope :without_nodes, lambda { |node_ids|
    ids = node_ids + Topic.topic_index_hide_node_ids
    ids.uniq!
    exclude_column_ids("node_id", ids)
  }

  mapping do
    indexes :title, term_vector: :yes
    indexes :body, term_vector: :yes
  end

  def as_indexed_json(_options = {})
    {
      title: self.title,
      body: self.full_body
    }
  end

  def indexed_changed?
    saved_change_to_title? || saved_change_to_body?
  end

  def related_topics(size = 5)
    opts = {
      query: {
        more_like_this: {
          fields: [:title, :body],
          docs: [
            {
              _index: self.class.index_name,
              _type: self.class.document_type,
              _id: id
            }
          ],
          min_term_freq: 2,
          min_doc_freq: 5
        }
      },
      size: size
    }
    self.class.__elasticsearch__.search(opts).records.to_a
  end

  def self.fields_for_list
    columns = %w(body who_deleted)
    select(column_names - columns.map(&:to_s))
  end

  def full_body
    ([self.body] + self.replies.pluck(:body)).join('\n\n')
  end

  def self.topic_index_hide_node_ids
    Setting.node_ids_hide_in_topics_index.to_s.split(",").collect(&:to_i)
  end

  before_save :store_cache_fields
  def store_cache_fields
    self.node_name = node.try(:name) || ""
  end

  before_save :auto_correct_title
  def auto_correct_title
    CORRECT_CHARS.each do |chars|
      title.gsub!(chars[0], chars[1])
    end
    title.auto_space!
  end
  before_save do
    if admin_editing == true && self.node_id_changed?
      Topic.notify_topic_node_changed(id, node_id)
    end
  end

  before_create :init_last_active_mark_on_create
  def init_last_active_mark_on_create
    self.last_active_mark = Time.now.to_i
  end

  after_commit :async_create_reply_notify, on: :create
  def async_create_reply_notify
    NotifyTopicJob.perform_later(id)
  end

  def update_last_reply(reply, opts = {})
    # replied_at 用于最新回复的排序，如果帖着创建时间在一个月以前，就不再往前面顶了
    return false if reply.blank? && !opts[:force]

    self.last_active_mark = Time.now.to_i if created_at > 1.month.ago
    self.replied_at = reply.try(:created_at)
    self.replies_count = replies.without_system.count
    self.last_reply_id = reply.try(:id)
    self.last_reply_user_id = reply.try(:user_id)
    self.last_reply_user_login = reply.try(:user_login)
    # Reindex Search document
    SearchIndexer.perform_later("update", "topic", self.id)
    save
  end

  # 更新最后更新人，当最后个回帖删除的时候
  def update_deleted_last_reply(deleted_reply)
    return false if deleted_reply.blank?
    return false if last_reply_user_id != deleted_reply.user_id

    previous_reply = replies.without_system.where.not(id: deleted_reply.id).recent.first
    update_last_reply(previous_reply, force: true)
  end

  # 删除并记录删除人
  def destroy_by(user)
    return false if user.blank?
    update_attribute(:who_deleted, user.login)
    destroy
  end

  def destroy
    super
    delete_notifiaction_mentions
  end

  # 所有的回复编号
  def reply_ids
    Rails.cache.fetch([self, "reply_ids"]) do
      self.replies.order("id asc").pluck(:id)
    end
  end

  def excellent?
    excellent >= 1
  end

  def ban!(opts = {})
    transaction do
      update(lock_node: true, node_id: Node.no_point.id, admin_editing: true)
      if opts[:reason]
        Reply.create_system_event(action: "ban", topic_id: self.id, body: opts[:reason])
      end
    end
  end

  def excellent!
    transaction do
      Reply.create_system_event(action: "excellent", topic_id: self.id)
      update!(excellent: 1)
    end
  end

  def unexcellent!
    transaction do
      Reply.create_system_event(action: "unexcellent", topic_id: self.id)
      update!(excellent: 0)
    end
  end

  def floor_of_reply(reply)
    reply_index = reply_ids.index(reply.id)
    reply_index + 1
  end

  def hot_hits_incr(num)
    current_time = Time.now
    
    last_update_time = self.last_update_time_for_hits.try(:value) || current_time.to_s
    last_update_time = last_update_time.to_datetime 

    hours_diff = (current_time.change(min: 0) - last_update_time.change(min:0)) / 3600
    days_diff = (current_time.change(hour: 0) - last_update_time.change(hour: 0)) / 86400

    hours_diff.to_i.times { self.recent_day_hits << 0 }
    days_diff.to_i.times { self.seven_days_hits << 0 }

    if self.seven_days_hits.last.nil?
      self.seven_days_hits << num
    else
      tmp_week_hits = self.seven_days_hits[-1].to_i
      tmp_week_hits += num
      self.seven_days_hits[-1] = tmp_week_hits
    end

    if self.recent_day_hits.last.nil?
      self.recent_day_hits << num
    else
      tmp_hour_hits = self.recent_day_hits[-1].to_i
      tmp_hour_hits += num
      self.recent_day_hits[-1] = tmp_hour_hits
    end

    self.last_update_time_for_hits.value = current_time.to_s
  end

  # 问题一周内的回复数，按天排序
  def last_week_replies_count
    replies = self.replies.within_seven_days
    result_hash = get_last_week_hash
    
    replies.each do |reply|
      date = reply.created_at.utc.strftime("%m%d")
      result_hash[date] += 1
    end
    
    last_week_count = result_hash.values.reverse
    last_week_count
  end

  # 问题24小时内的回复数，按小时排序
  def last_day_replies_count
    replies = self.replies.within_one_day
    result_hash = get_last_day_hash

    replies.each do |reply|
      hour = reply.created_at.utc.strftime("%H")
      result_hash[hour] += 1
    end
  
    last_day_count = result_hash.values.reverse
    last_day_count
  end

  # 获取7天内的访问数据
  def get_last_week_hits_count
    tmp_count_array = self.seven_days_hits.to_a
    tmp_count_array = unshift_fill_array(tmp_count_array, 7)
    tmp_count_array
  end

  # 获取24小时内的访问数据
  def get_last_day_hits_count
    tmp_count_array = self.recent_day_hits.to_a
    tmp_count_array = unshift_fill_array(tmp_count_array, 24)
    tmp_count_array
  end

  def self.notify_topic_created(topic_id)
    topic = Topic.find_by_id(topic_id)
    return unless topic && topic.user

    follower_ids = topic.user.follow_by_user_ids
    return if follower_ids.empty?

    notified_user_ids = topic.mentioned_user_ids

    # 给关注者发通知
    default_note = { notify_type: "topic", target_type: "Topic", target_id: topic.id, actor_id: topic.user_id }
    Notification.bulk_insert(set_size: 100) do |worker|
      follower_ids.each do |uid|
        # 排除同一个回复过程中已经提醒过的人
        next if notified_user_ids.include?(uid)
        # 排除回帖人
        next if uid == topic.user_id
        note = default_note.merge(user_id: uid)
        worker.add(note)
      end
    end

    true
  end

  def self.notify_topic_node_changed(topic_id, node_id)
    topic = Topic.find_by_id(topic_id)
    return if topic.blank?
    node = Node.find_by_id(node_id)
    return if node.blank?

    Notification.create notify_type: "node_changed",
                        user_id: topic.user_id,
                        target: topic,
                        second_target: node
    true
  end

  def self.total_pages
    return @total_pages if defined? @total_pages

    total_count = Rails.cache.fetch("topics/total_count", expires_in: 1.week) do
      self.unscoped.count
    end
    if total_count >= 1500
      @total_pages = 60
    end
    @total_pages
  end

  private

  def unshift_fill_array(array, num)
    tmp_array = array.dup
    len = tmp_array.size
    return tmp_array if len >= num

    while len < num
      tmp_array.unshift(0)
      len += 1
    end
    tmp_array
  end

  def get_last_week_hash
    tmp_week_hash = {}
    current_time = Time.now.utc
    
    7.times do |i|
      date = (current_time - i.days).strftime("%m%d")
      tmp_week_hash[date] = 0
    end
    tmp_week_hash
  end

  def get_last_day_hash
    tmp_day_hash = {}
    current_time = Time.now.utc
    
    24.times do |i|
      hour = (current_time - i.hours).strftime("%H")
      tmp_day_hash[hour] = 0
    end
    tmp_day_hash
  end
end
