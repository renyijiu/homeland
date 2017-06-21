module UpdateScore
  extend ActiveSupport::Concern

  included do
    after_commit on: :create do
      current_topic_id = self.class.name == "Topic" ? self.id : self.topic_id
      current_topic = Topic.find_by_id(current_topic_id)

      week_visit_count = current_topic.get_last_week_hits_count
      day_visit_count = current_topic.get_last_day_hits_count

      week_replies_count = current_topic.last_week_replies_count
      day_replies_count = current_topic.last_day_replies_count

      week_score = cal_score_for_topic(week_visit_count, week_replies_count)
      day_score = cal_score_for_topic(day_visit_count, day_replies_count)

      transaction do
        current_topic.day_score = day_score
        current_topic.week_score = week_score
        current_topic.save
      end
    end
  end

  def cal_score_for_topic(visit_count, replies_count)
    score = 0
    return score unless visit_count.size == replies_count.size
    
    len = visit_count.size
    len.times do |i|
      tmp_visit_value = visit_count[i].to_i
      tmp_replies_value = replies_count[i].to_i

      score += ((tmp_visit_value + tmp_replies_value*3) * (i + 1))
    end
    score
  end
end
