module Msf
class DBManager

class Host < ActiveRecord::Base
	include DBSave

	belongs_to :workspace
	has_and_belongs_to_many :tags, :join_table => :hosts_tags
	has_many :services, :dependent => :destroy
	has_many :clients,  :dependent => :destroy
	has_many :vulns,    :dependent => :destroy
	has_many :notes,    :dependent => :destroy
	has_many :loots,    :dependent => :destroy, :order => "loots.created_at desc"

	has_many :service_notes, :through => :services
	has_many :web_sites, :through => :services
	has_many :creds,    :through   => :services
	has_many :exploited_hosts, :dependent => :destroy

	validates_exclusion_of :address, :in => ['127.0.0.1']
	validates_uniqueness_of :address, :scope => :workspace_id

    def attribute_locked?(attr)
      n = notes.find_by_ntype("host.updated.#{attr}")
	  n && n.data[:locked]
    end

end

end
end
