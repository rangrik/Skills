# backend/app/routes/export_routes.py
#
# New endpoint added in this PR: lets a signed-in user request an export
# of their data and get back a download URL.

import os

from fastapi import APIRouter
from sqlalchemy import select

from app.database.session import get_session
from app.models.export import Export
from app.services.export_writer import write_export_file


router = APIRouter()


@router.post("/exports")
async def create_export(user_id: str, export_format: str):
    db = get_session()

    # validate the requested format
    if export_format not in ("csv", "xlsx", "json"):
        return {"error": "unsupported format"}

    # enforce the per-user daily export quota
    result = await db.execute(select(Export).where(Export.user_id == user_id))
    todays = [e for e in result.scalars().all() if e.created_at.date() == _today()]
    quota = int(os.environ["MAX_EXPORTS_PER_DAY"])
    if len(todays) >= quota:
        return {"error": "daily quota exceeded"}

    # create the export record
    export = Export(user_id=user_id, format=export_format, status="pending")
    db.add(export)
    await db.commit()

    # generate the file right here so we can return a download URL in the response
    rows = await db.execute(select(Export).where(Export.user_id == user_id))
    url = write_export_file(export.id, rows.scalars().all())

    export.status = "done"
    export.download_url = url
    await db.commit()

    return {"id": str(export.id), "status": "done", "download_url": url}
