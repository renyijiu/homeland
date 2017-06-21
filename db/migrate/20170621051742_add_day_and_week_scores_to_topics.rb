class AddDayAndWeekScoresToTopics < ActiveRecord::Migration[5.1]
  def change
    add_column :topics, :day_score, :integer, default: 0
    add_column :topics, :week_score, :integer, default: 0
  end
end
